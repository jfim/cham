defmodule Cham.Pipeline do
  alias Cham.Items
  alias Cham.Archive.{ArchiveManager, FilesystemManager}

  @doc """
  Submit a URL for processing. Creates an item, input artifact,
  and bootstrap directory. Returns {:ok, item} or {:error, changeset}.

  Options:
  - root: archive root directory (default: ".")
  - tags: list of user-supplied tags
  """
  def submit_url(url, opts \\ []) do
    root = Keyword.get(opts, :root, ".")
    tags = Keyword.get(opts, :tags, [])

    with {:ok, item} <- Items.create_item(%{url: url, tags: tags}),
         {:ok, item} <- setup_bootstrap(item, root),
         {:ok, _artifact} <- create_input_artifact(item, url) do
      Cham.EventBus.publish("item:created", %{item: item})
      Cham.Pipeline.Orchestrator.kick_off(item.id)
      {:ok, item}
    end
  end

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

        case Items.update_item(item, %{status: "processing"}) do
          {:ok, updated} ->
            Cham.EventBus.publish("item:reprocessed", %{item: updated})
            Cham.Pipeline.Orchestrator.kick_off(updated.id)
            {:ok, updated}

          {:error, changeset} ->
            {:error, changeset}
        end
    end
  end

  defp clear_failed_executions(item_id) do
    import Ecto.Query

    Cham.Repo.delete_all(
      from se in Cham.JobTracking.StageExecution,
        where: se.item_id == ^item_id and se.status == "failed"
    )
  end

  defp invalidate_stage(item_id, stage_id) do
    stages = Cham.Plugin.Registry.get_stages()
    downstream = Cham.Pipeline.DAG.find_downstream_stages(stages, stage_id)
    all_ids = [stage_id | Enum.map(downstream, & &1.plugin_id)]

    Enum.each(all_ids, &clear_stage(item_id, &1))
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

  defp extract_domain(url) do
    uri = URI.parse(url)
    uri.host || "unknown"
  end
end
