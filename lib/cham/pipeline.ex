defmodule Cham.Pipeline do
  alias Cham.Archive.{ArchiveManager, FilesystemManager}
  alias Cham.Items
  alias Cham.Items.Events.{ItemCreated, ItemStatusChanged}

  @doc """
  Submit a URL for processing. Creates an item, input artifact,
  and bootstrap directory. Returns {:ok, item} or {:error, changeset}.

  Options:
  - root: archive root directory (default: ".")
  - tags: list of user-supplied tags
  - subscription_id: UUID of the subscription this item belongs to (optional)
  - source_item_id: source-feed identifier for deduplication (optional)
  - title: pre-fetched title from the feed (optional)
  """
  def submit_url(url, opts \\ []) do
    root = Keyword.get(opts, :root, archive_root())
    tags = Keyword.get(opts, :tags, [])

    item_attrs =
      %{url: url, tags: tags}
      |> maybe_put(:subscription_id, Keyword.get(opts, :subscription_id))
      |> maybe_put(:source_item_id, Keyword.get(opts, :source_item_id))
      |> maybe_put(:title, Keyword.get(opts, :title))

    with {:ok, item} <- Items.create_item(item_attrs),
         {:ok, item} <- setup_bootstrap(item, root),
         {:ok, _artifact} <- create_input_artifact(item, url) do
      Cham.EventBus.publish("item:created", %ItemCreated{item_id: item.id, url: item.url})
      Cham.Pipeline.Orchestrator.kick_off(item.id)
      {:ok, item}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc """
  Reprocess an existing item. Resets status to "processing" and kicks off
  the orchestrator, which will skip already-completed stages and run any new ones.

  Options:
  - retry_failed: if true, clears failed stage executions so they can be retried
  - invalidate: list of stage plugin_ids to clear (removes their executions and artifacts)
  """
  def reprocess(item_id, opts \\ []) do
    retry_failed = Keyword.get(opts, :retry_failed, false)
    invalidate = Keyword.get(opts, :invalidate, [])

    case Items.get_item(item_id) do
      nil ->
        {:error, :not_found}

      item ->
        if retry_failed, do: clear_failed_executions(item_id)
        Enum.each(invalidate, &invalidate_stage(item_id, &1))

        # Phase is "bootstrapping" until at least one origin:original artifact
        # exists. archive_path being set is not sufficient — an item can have an
        # archive_path but still be missing its original (e.g. the fetcher never
        # produced output). Without this, the orchestrator's fallback-fetcher
        # mechanism (maybe_add_fallback/4, which only runs in bootstrapping
        # phase) is skipped and reprocess does nothing useful.
        reprocess_status =
          if has_original_artifact?(item_id), do: "processing", else: "bootstrapping"

        case Items.update_item(item, %{status: reprocess_status}) do
          {:ok, updated} ->
            Cham.EventBus.publish("item:reprocessed", %{item: updated})
            Cham.Pipeline.Orchestrator.kick_off(updated.id)
            {:ok, updated}

          {:error, changeset} ->
            {:error, changeset}
        end
    end
  end

  @terminal_statuses ~w(complete incomplete failed cancelled)

  @doc """
  Cancel an in-progress item. Sets status to "cancelled" and cancels
  all pending Oban jobs for the item. Currently executing jobs will
  finish but their results are discarded by StageWorker.
  """
  def cancel(item_id) do
    case Items.get_item(item_id) do
      nil ->
        {:error, :not_found}

      %{status: status} when status in @terminal_statuses ->
        {:error, :already_terminal}

      item ->
        cancel_oban_jobs(item_id)

        case Items.update_item(item, %{status: "cancelled"}) do
          {:ok, updated} ->
            Cham.EventBus.publish("item:status_changed", %ItemStatusChanged{
              item_id: updated.id,
              status: "cancelled"
            })

            {:ok, updated}

          {:error, changeset} ->
            {:error, changeset}
        end
    end
  end

  defp cancel_oban_jobs(item_id) do
    import Ecto.Query

    active_states = ~w(available executing scheduled retryable)

    job_ids =
      Cham.Repo.all(
        from j in "oban_jobs",
          where:
            j.worker == "Cham.Pipeline.StageWorker" and
              j.state in ^active_states and
              fragment("?->>'item_id' = ?", j.args, ^item_id),
          select: j.id
      )

    Enum.each(job_ids, &Oban.cancel_job(&1))
  end

  defp has_original_artifact?(item_id) do
    Items.list_artifacts(item_id)
    |> Enum.any?(fn a ->
      a.status == "produced" and Map.get(a.labels || %{}, "origin") == "original"
    end)
  end

  defp clear_failed_executions(item_id) do
    import Ecto.Query

    Cham.Repo.delete_all(
      from se in Cham.JobTracking.StageExecution,
        where: se.item_id == ^item_id and se.status == "failed"
    )
  end

  defp invalidate_stage(item_id, stage_id) do
    artifacts = Items.list_artifacts(item_id)
    stages = Cham.Plugin.Registry.get_stages()

    to_clear = dependent_stages(artifacts, stages, MapSet.new([stage_id]))

    Enum.each(to_clear, &clear_stage(item_id, &1))
  end

  # Walks the per-item artifact graph forward from `accumulated` stages,
  # adding any other stage S where (a) S produced an artifact for this item,
  # (b) S's input_matchers match the labels of an already-cleared artifact,
  # and (c) S's artifact was produced after the cleared one (so S could
  # plausibly have consumed it).
  #
  # Per-item rather than abstract DAG — so a fallback downloader with a
  # match-all matcher that ran before the invalidated stage doesn't get
  # flagged as a downstream consumer.
  defp dependent_stages(artifacts, stages, accumulated) do
    cleared = Enum.filter(artifacts, fn a -> MapSet.member?(accumulated, a.stage) end)

    earliest_cleared_at =
      cleared
      |> Enum.map(& &1.started_at)
      |> Enum.reject(&is_nil/1)
      |> case do
        [] -> nil
        ts -> Enum.min(ts, DateTime)
      end

    cleared_labels = Enum.map(cleared, & &1.labels)

    new_stages =
      artifacts
      |> Enum.reject(fn a -> MapSet.member?(accumulated, a.stage) end)
      |> Enum.filter(fn a -> ran_after?(a, earliest_cleared_at) end)
      |> Enum.filter(&consumes_any?(&1, stages, cleared_labels))
      |> Enum.map(& &1.stage)
      |> MapSet.new()

    if MapSet.size(new_stages) == 0 do
      accumulated
    else
      dependent_stages(artifacts, stages, MapSet.union(accumulated, new_stages))
    end
  end

  defp ran_after?(_a, nil), do: false
  defp ran_after?(%{started_at: nil}, _t), do: false
  defp ran_after?(%{started_at: at}, t), do: DateTime.compare(at, t) == :gt

  defp consumes_any?(artifact, stages, labels_to_match) do
    case Enum.find(stages, &(&1.plugin_id == artifact.stage)) do
      nil ->
        false

      stage_def ->
        Enum.any?(stage_def.input_matchers, fn matcher ->
          Enum.any?(labels_to_match, &Cham.Pipeline.LabelMatcher.matches?(&1, matcher))
        end)
    end
  end

  defp clear_stage(item_id, stage_id) do
    import Ecto.Query

    Cham.Repo.delete_all(
      from se in Cham.JobTracking.StageExecution,
        where: se.item_id == ^item_id and se.stage == ^stage_id
    )

    Cham.Repo.delete_all(
      from a in Cham.Items.Artifact,
        where: a.item_id == ^item_id and a.stage == ^stage_id
    )
  end

  defp setup_bootstrap(item, root) do
    bootstrap_path = ArchiveManager.bootstrap_path(root, item.id)
    FilesystemManager.mkdir_p(bootstrap_path)
    Items.update_item(item, %{bootstrap_path: bootstrap_path})
  end

  defp create_input_artifact(item, url) do
    domain = extract_domain(url)
    start_ts = DateTime.utc_now() |> DateTime.to_unix()

    # Create the input stage directory
    {:ok, stage_dir} = ArchiveManager.create_stage_dir(item.bootstrap_path, "input")

    # Write artifact.json
    data = %{
      "stage" => %{"plugin_id" => "input", "start_ts" => start_ts, "end_ts" => start_ts},
      "artifacts" => [%{"labels" => %{"domain" => domain}, "filenames" => []}],
      "item_metadata" => %{"url" => url}
    }

    FilesystemManager.atomic_write(
      Path.join(stage_dir, "artifact.json"),
      Jason.encode!(data, pretty: true)
    )

    # Record in DB
    relative_path = "processing/#{Path.basename(stage_dir)}"

    Items.create_artifact(%{
      item_id: item.id,
      stage: "input",
      labels: %{"domain" => domain},
      filenames: [],
      path: relative_path,
      status: "produced"
    })
  end

  defp archive_root do
    Application.get_env(:cham, :archive_root, ".")
  end

  defp extract_domain(url) do
    uri = URI.parse(url)
    uri.host || "unknown"
  end
end
