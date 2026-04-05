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
  alias Cham.Pipeline.{DAG, StageWorker}
  alias Cham.Plugin.Registry

  @terminal_statuses ~w(complete incomplete failed)

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

      ready =
        DAG.find_next_stages(stages, artifacts, excluded_ids)

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

    Cham.Repo.all(
      from se in Cham.JobTracking.StageExecution,
        where: se.item_id == ^item_id and se.status == "failed",
        select: se.stage
    )
    |> MapSet.new()
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

    cond do
      not MapSet.disjoint?(failed, original_stage_ids(stages)) ->
        Logger.warning("Item #{item.id} has failed original-producing stages, marking failed")
        Items.update_item(item, %{status: "failed", error_message: "original stage failed"})

      DAG.all_originals_complete?(stages, artifacts, completed_ids) ->
        transition_to_archive(item, state)

      true ->
        :ok
    end
  end

  defp check_processing_transitions(item, _state) do
    artifacts = Items.list_artifacts(item.id)
    active = active_oban_stage_ids(item.id)

    # Remove the just-completed job from active set consideration
    # (it may still show as completed in DB). Check if there are no
    # remaining active jobs and no more ready stages to run.
    if MapSet.size(active) == 0 do
      failed = failed_stage_ids(item.id)

      has_failed_executions = MapSet.size(failed) > 0

      if has_failed_executions do
        Items.update_item(item, %{status: "incomplete"})
      else
        completed_count =
          Enum.count(artifacts, &(&1.status == "produced"))

        if completed_count > 0 do
          Items.update_item(item, %{status: "complete"})
        end
      end
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
        evaluate_and_enqueue(updated_item.id, state)

      {:error, reason} ->
        Logger.error("Failed to move item #{item.id} to archive: #{inspect(reason)}")
        Items.update_item(item, %{status: "failed", error_message: "archive move failed"})
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
