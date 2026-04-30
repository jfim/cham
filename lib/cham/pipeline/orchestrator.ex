defmodule Cham.Pipeline.Orchestrator do
  @moduledoc """
  GenServer that serializes pipeline scheduling decisions.

  After each stage completes or fails, evaluates what to run next
  and handles item state transitions (bootstrapping → processing → complete).
  """

  use GenServer
  require Logger

  alias Cham.Archive.ArchiveManager
  alias Cham.Items
  alias Cham.Items.Events.{ItemArchived, ItemStatusChanged}
  alias Cham.Pipeline.{DAG, DesiredStages, StageWorker}
  alias Cham.Pipeline.Events.PipelineComplete
  alias Cham.Plugin.Registry

  @terminal_statuses ~w(complete incomplete failed cancelled)

  # ── Public API (fire-and-forget casts) ──

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Finds first ready stages for an item and enqueues them."
  def kick_off(server \\ __MODULE__, item_id) do
    GenServer.cast(server, {:kick_off, item_id})
  end

  @doc "Called when a stage completes. Evaluates next stages and checks transitions."
  def stage_completed(server \\ __MODULE__, item_id, plugin_id) do
    GenServer.cast(server, {:stage_completed, item_id, plugin_id})
  end

  @doc "Called when a stage permanently fails. Logs and checks transitions."
  def stage_failed(server \\ __MODULE__, item_id, plugin_id, error) do
    GenServer.cast(server, {:stage_failed, item_id, plugin_id, error})
  end

  # ── GenServer callbacks ──

  @impl true
  def init(opts) do
    registry = Keyword.get(opts, :registry, Registry)
    recovery_interval = Keyword.get(opts, :recovery_interval, :timer.seconds(30))

    state = %{registry: registry, recovery_interval: recovery_interval}
    {:ok, state, {:continue, :recover}}
  end

  @impl true
  def handle_continue(:recover, state) do
    recover(state)
    schedule_recovery(state)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:kick_off, item_id}, state) do
    evaluate_and_enqueue(item_id, state)
    {:noreply, state}
  end

  def handle_cast({:stage_completed, item_id, _plugin_id}, state) do
    evaluate_and_enqueue(item_id, state)
    check_transitions(item_id, state)
    {:noreply, state}
  end

  def handle_cast({:stage_failed, item_id, plugin_id, error}, state) do
    Logger.warning("Stage #{plugin_id} permanently failed for item #{item_id}: #{error}")
    check_transitions(item_id, state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:recover, state) do
    recover(state)
    schedule_recovery(state)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Internal functions ──

  defp recover(state) do
    items =
      Items.list_items(status: "bootstrapping") ++ Items.list_items(status: "processing")

    Enum.each(items, fn item ->
      evaluate_and_enqueue(item.id, state)
      check_transitions(item.id, state)
    end)
  end

  defp schedule_recovery(%{recovery_interval: :infinity}), do: :ok

  defp schedule_recovery(%{recovery_interval: interval}) do
    Process.send_after(self(), :recover, interval)
  end

  defp evaluate_and_enqueue(item_id, state) do
    item = Items.get_item!(item_id)

    if item.status in @terminal_statuses do
      :skip
    else
      artifacts = Items.list_artifacts(item_id)
      excluded_ids = build_exclusion_set(item_id, artifacts)
      stages = Registry.get_stages(state.registry)

      dag_ready = DAG.find_next_stages(stages, artifacts, excluded_ids)

      ready =
        dag_ready
        |> filter_by_phase(item.status)
        |> DesiredStages.filter_stages(item.content_type, stages)
        |> maybe_add_fallback(item, stages, excluded_ids)

      Enum.each(ready, fn stage ->
        changeset =
          StageWorker.new(
            %{
              "item_id" => item_id,
              "stage_module" => Atom.to_string(stage.module),
              "plugin_id" => stage.plugin_id
            },
            queue: stage.queue,
            max_attempts: stage.max_attempts
          )

        case Cham.Repo.insert(changeset) do
          {:ok, _job} ->
            Logger.debug("Enqueued stage #{stage.plugin_id} for item #{item_id}")

          {:error, reason} ->
            Logger.error(
              "Failed to enqueue stage #{stage.plugin_id} for item #{item_id}: #{inspect(reason)}"
            )
        end
      end)
    end
  end

  defp filter_by_phase(stages, "bootstrapping") do
    Enum.filter(stages, fn stage ->
      Enum.any?(stage.output_labels, &(Map.get(&1, "origin") == "original"))
    end)
  end

  defp filter_by_phase(stages, _status), do: stages

  defp maybe_add_fallback(ready_stages, item, all_stages, excluded_ids) do
    if item.status != "bootstrapping" do
      ready_stages
    else
      # Check if any bootstrap stage (producing initial_download) is either
      # ready to run or already active/completed/failed (in the exclusion set)
      fallback_id = get_fallback_stage_id()

      bootstrap_stages =
        Enum.filter(all_stages, fn stage ->
          stage.plugin_id != fallback_id and
            Enum.any?(stage.output_labels, &(Map.get(&1, "type") == "initial_download"))
        end)

      has_bootstrap_stage =
        Enum.any?(bootstrap_stages, fn stage ->
          Enum.any?(ready_stages, &(&1.plugin_id == stage.plugin_id)) or
            MapSet.member?(excluded_ids, stage.plugin_id)
        end)

      if has_bootstrap_stage do
        ready_stages
      else
        if fallback_id && not MapSet.member?(excluded_ids, fallback_id) do
          case Enum.find(all_stages, &(&1.plugin_id == fallback_id)) do
            nil -> ready_stages
            fallback -> ready_stages ++ [fallback]
          end
        else
          ready_stages
        end
      end
    end
  end

  defp get_fallback_stage_id do
    config = Cham.Plugin.Config.read("pipeline")
    Map.get(config, :fallback_bootstrap_stage, "generic_download_url")
  end

  defp build_exclusion_set(item_id, artifacts) do
    # Stages that produced artifacts
    completed_by_artifacts =
      artifacts
      |> Enum.filter(&(&1.status == "produced"))
      |> Enum.map(& &1.stage)
      |> MapSet.new()

    # Stages that completed (including metadata-only stages that produce no artifacts)
    completed_by_execution = completed_stage_ids(item_id)

    failed = failed_stage_ids(item_id)
    active = active_oban_stage_ids(item_id)

    completed_by_artifacts
    |> MapSet.union(completed_by_execution)
    |> MapSet.union(failed)
    |> MapSet.union(active)
  end

  defp completed_stage_ids(item_id) do
    import Ecto.Query

    Cham.Repo.all(
      from se in Cham.JobTracking.StageExecution,
        where: se.item_id == ^item_id and se.status == "completed",
        select: se.stage
    )
    |> MapSet.new()
  end

  defp failed_stage_ids(item_id) do
    import Ecto.Query

    failed =
      Cham.Repo.all(
        from se in Cham.JobTracking.StageExecution,
          where: se.item_id == ^item_id and se.status == "failed",
          select: se.stage
      )
      |> MapSet.new()

    # A stage that failed on one attempt and later completed on retry is a
    # success — transient errors shouldn't latch an item into failed.
    MapSet.difference(failed, completed_stage_ids(item_id))
  end

  defp active_oban_stage_ids(item_id) do
    import Ecto.Query

    active_states = ~w(available executing scheduled retryable)

    Cham.Repo.all(
      from j in "oban_jobs",
        where:
          j.worker == "Cham.Pipeline.StageWorker" and
            j.state in ^active_states and
            fragment("?->>'item_id' = ?", j.args, ^item_id),
        select: fragment("?->>'plugin_id'", j.args)
    )
    |> MapSet.new()
  end

  defp check_transitions(item_id, state) do
    item = Items.get_item!(item_id)

    case item.status do
      "bootstrapping" ->
        check_bootstrapping_transitions(item, state)

      "processing" ->
        check_processing_transitions(item, state)

      _ ->
        :ok
    end
  end

  defp check_bootstrapping_transitions(item, state) do
    stages = Registry.get_stages(state.registry)
    artifacts = Items.list_artifacts(item.id)

    completed_ids =
      artifacts
      |> Enum.filter(&(&1.status == "produced"))
      |> Enum.map(& &1.stage)
      |> MapSet.new()

    failed = failed_stage_ids(item.id)

    active = active_oban_stage_ids(item.id)

    cond do
      not MapSet.disjoint?(failed, original_stage_ids(stages)) ->
        Logger.warning("Item #{item.id} has failed original-producing stages, marking failed")
        transition_to_terminal(item, "failed", "original stage failed")

      # If a fetch is currently enqueued/running, don't race ahead and declare
      # bootstrap complete. all_originals_complete? returns true vacuously when
      # no original-producing stage is "reachable" via the normal DAG (the
      # fallback fetcher's can_process? returns :not_applicable), and without
      # this guard a freshly-kicked-off item would archive itself before its
      # fetch even runs.
      MapSet.size(active) > 0 ->
        :ok

      DAG.all_originals_complete?(stages, artifacts, completed_ids) ->
        transition_to_archive(item, state)

      true ->
        :ok
    end
  end

  defp check_processing_transitions(item, state) do
    artifacts = Items.list_artifacts(item.id)
    active = active_oban_stage_ids(item.id)

    if MapSet.size(active) == 0 do
      # Before transitioning, check if the DAG still has ready stages to run.
      # This prevents marking an item complete when new stages (e.g. from a
      # newly registered plugin) are available but haven't been enqueued yet.
      excluded_ids = build_exclusion_set(item.id, artifacts)
      stages = Registry.get_stages(state.registry)

      ready =
        DAG.find_next_stages(stages, artifacts, excluded_ids)
        |> DesiredStages.filter_stages(item.content_type, stages)

      if ready != [] do
        # There are more stages to run — don't transition yet.
        # Enqueue them instead.
        evaluate_and_enqueue(item.id, state)
      else
        failed = failed_stage_ids(item.id)

        produced_non_input =
          Enum.count(artifacts, &(&1.status == "produced" and &1.stage != "input"))

        cond do
          MapSet.size(failed) > 0 ->
            transition_to_terminal(item, "incomplete")

          produced_non_input > 0 ->
            transition_to_terminal(item, "complete")

          true ->
            # No active jobs, no ready stages, no failed stages, and no real
            # output produced — only the synthetic input artifact exists. The
            # pipeline has nothing more to do for this item, so mark it
            # incomplete rather than leaving it stuck in "processing".
            transition_to_terminal(item, "incomplete", "no pipeline stages produced output")
        end
      end
    end
  end

  defp transition_to_terminal(item, status, error_message \\ nil) do
    # Always set :error_message: pass the new message when present, otherwise
    # explicitly clear any stale message so a successful transition doesn't
    # carry over an error from a previous failed run.
    attrs = %{status: status, error_message: error_message}

    case Items.update_item(item, attrs) do
      {:ok, updated} ->
        Cham.EventBus.publish("item:status_changed", %ItemStatusChanged{
          item_id: updated.id,
          status: status
        })

        if status in @terminal_statuses do
          Cham.EventBus.publish("pipeline:complete", %PipelineComplete{
            item_id: updated.id,
            status: status
          })
        end

        {:ok, updated}

      error ->
        error
    end
  end

  defp original_stage_ids(stages) do
    stages
    |> Enum.filter(fn stage ->
      Enum.any?(stage.output_labels, fn labels ->
        Map.get(labels, "origin") == "original"
      end)
    end)
    |> Enum.map(& &1.plugin_id)
    |> MapSet.new()
  end

  defp transition_to_archive(item, state) do
    slug = generate_slug(item)
    root = archive_root()

    cond do
      # Already archived — just transition phase, no filesystem work to do.
      is_nil(item.bootstrap_path) and not is_nil(item.archive_path) ->
        {:ok, updated_item} = Items.update_item(item, %{status: "processing"})
        evaluate_and_enqueue(updated_item.id, state)

      # No bootstrap_path AND no archive_path — inconsistent state we can't
      # recover from automatically. Mark failed rather than crashing on
      # File.rename(nil, _).
      is_nil(item.bootstrap_path) ->
        Logger.error(
          "Cannot archive item #{item.id}: bootstrap_path and archive_path are both nil"
        )

        transition_to_terminal(item, "failed", "no bootstrap_path to archive from")

      true ->
        do_move_to_archive(item, root, slug, state)
    end
  end

  defp do_move_to_archive(item, root, slug, state) do
    case ArchiveManager.move_to_archive(root, item.bootstrap_path, slug, Date.utc_today()) do
      {:ok, archive_path} ->
        {:ok, updated_item} =
          Items.update_item(item, %{
            status: "processing",
            archive_path: archive_path,
            slug: slug,
            bootstrap_path: nil
          })

        Logger.info("Item #{item.id} transitioned to archive at #{archive_path}")

        Cham.EventBus.publish("item:archived", %ItemArchived{
          item_id: updated_item.id,
          slug: slug,
          archive_path: archive_path
        })

        evaluate_and_enqueue(updated_item.id, state)

      {:error, reason} ->
        Logger.error("Failed to move item #{item.id} to archive: #{inspect(reason)}")
        transition_to_terminal(item, "failed", "archive move failed")
    end
  end

  defp generate_slug(item) do
    id_suffix = String.slice(item.id, 0, 6)

    base =
      if item.title && item.title != "" do
        slugify(item.title)
      else
        slugify(item.url)
      end

    "#{base}-#{id_suffix}"
  end

  defp slugify(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s\-]/, "")
    |> String.replace(~r/[\s\-]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 80)
  end

  defp archive_root do
    Application.get_env(:cham, :archive_root, ".")
  end
end
