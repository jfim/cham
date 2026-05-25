defmodule Cham.JobTracking.Tracker do
  use GenServer

  alias Cham.JobTracking.StageExecution

  alias Cham.Pipeline.Events.{
    StageCompleted,
    StageFailed,
    StageProgress,
    StageSnoozed,
    StageStarted
  }

  alias Cham.Repo

  import Ecto.Query

  require Logger

  @oban_exception_event [:oban, :job, :exception]
  @oban_telemetry_handler_id "cham-tracker-oban-exception"

  # --- Client API ---

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def get_stage_history(item_id) do
    StageExecution
    |> where([s], s.item_id == ^item_id)
    |> order_by([s], asc: s.started_at)
    |> Repo.all()
  end

  def get_progress(server \\ __MODULE__, item_id) do
    GenServer.call(server, {:get_progress, item_id})
  end

  # --- Server ---

  @impl true
  def init(_opts) do
    reconcile_orphaned_executions()
    Cham.EventBus.subscribe("pipeline")
    attach_oban_telemetry()
    Process.flag(:trap_exit, true)
    {:ok, %{progress: %{}}}
  end

  @impl true
  def terminate(_reason, _state) do
    :telemetry.detach(@oban_telemetry_handler_id)
    :ok
  end

  @doc """
  Mark any stage_executions still in "started" status as "crashed".
  At boot time no worker can still be running a prior stage, so any
  lingering "started" row is an orphan from a previous crash, restart,
  or ungraceful shutdown.
  """
  def reconcile_orphaned_executions do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    orphan_item_ids =
      StageExecution
      |> where([s], s.status == "started")
      |> select([s], s.item_id)
      |> Repo.all()
      |> Enum.uniq()

    {count, _} =
      StageExecution
      |> where([s], s.status == "started")
      |> Repo.update_all(
        set: [
          status: "crashed",
          ended_at: now,
          error: "process terminated before completion (reconciled at startup)"
        ]
      )

    stuck_count = reconcile_stuck_items(orphan_item_ids)

    if count > 0 do
      Logger.warning(
        "Tracker: reconciled #{count} orphaned stage execution(s) as crashed (#{stuck_count} item(s) moved to incomplete)"
      )
    end

    count
  end

  defp reconcile_stuck_items(item_ids) when item_ids == [], do: 0

  defp reconcile_stuck_items(item_ids) do
    {count, _} =
      Cham.Items.Item
      |> where([i], i.id in ^item_ids and i.status in ["processing", "bootstrapping"])
      |> Repo.update_all(set: [status: "incomplete"])

    count
  end

  defp attach_oban_telemetry do
    :telemetry.detach(@oban_telemetry_handler_id)

    :telemetry.attach(
      @oban_telemetry_handler_id,
      @oban_exception_event,
      &__MODULE__.handle_oban_exception/4,
      nil
    )
  end

  @doc false
  def handle_oban_exception(@oban_exception_event, _measurements, metadata, _config) do
    case metadata do
      %{job: %Oban.Job{worker: "Cham.Pipeline.StageWorker"} = job} ->
        # Only publish StageFailed when Oban has exhausted retries. A transient
        # crash on a non-final attempt would otherwise latch the StageExecution
        # row to "failed", causing the orchestrator's bootstrapping-phase check
        # to mark the item permanently failed before the retry runs.
        if final_attempt?(job) do
          Cham.EventBus.publish("pipeline:stage_failed", %StageFailed{
            stage_id: job.args["plugin_id"],
            item_id: job.args["item_id"],
            error: format_oban_exception(metadata),
            attempt: job.attempt
          })
        end

      _ ->
        :ok
    end
  rescue
    exception ->
      Logger.error(
        "Tracker telemetry handler failed: #{Exception.format(:error, exception, __STACKTRACE__)}"
      )
  end

  defp final_attempt?(%Oban.Job{attempt: attempt, max_attempts: max_attempts})
       when is_integer(attempt) and is_integer(max_attempts) do
    attempt >= max_attempts
  end

  # If max_attempts isn't on the job (older jobs, or hand-crafted in tests),
  # err on the side of publishing — preserves the historical behavior so
  # nothing silently disappears.
  defp final_attempt?(_job), do: true

  defp format_oban_exception(%{kind: kind, reason: reason, stacktrace: stacktrace}) do
    Exception.format(kind, reason, stacktrace)
  end

  defp format_oban_exception(%{reason: reason}), do: inspect(reason)
  defp format_oban_exception(_), do: "unknown error"

  @impl true
  def handle_info(%StageStarted{} = event, state) do
    now = DateTime.utc_now()

    %StageExecution{}
    |> StageExecution.changeset(%{
      item_id: event.item_id,
      stage: event.stage_id,
      status: "started",
      attempt: event.attempt || 1,
      started_at: now
    })
    |> Repo.insert!()

    {:noreply, state}
  end

  @impl true
  def handle_info(%StageCompleted{} = event, state) do
    now = DateTime.utc_now()

    StageExecution
    |> where(
      [s],
      s.item_id == ^event.item_id and s.stage == ^event.stage_id and s.status == "started"
    )
    |> order_by([s], desc: s.started_at)
    |> limit(1)
    |> Repo.one()
    |> case do
      nil ->
        :ok

      execution ->
        execution
        |> StageExecution.changeset(%{
          status: "completed",
          ended_at: now,
          duration_ms: event.duration_ms
        })
        |> Repo.update!()
    end

    new_progress = clear_stage_progress(state.progress, event.item_id, event.stage_id)
    {:noreply, %{state | progress: new_progress}}
  end

  @impl true
  def handle_info(%StageFailed{} = event, state) do
    now = DateTime.utc_now()

    StageExecution
    |> where(
      [s],
      s.item_id == ^event.item_id and s.stage == ^event.stage_id and s.status == "started"
    )
    |> order_by([s], desc: s.started_at)
    |> limit(1)
    |> Repo.one()
    |> case do
      nil ->
        :ok

      execution ->
        execution
        |> StageExecution.changeset(%{
          status: "failed",
          ended_at: now,
          error: event.error
        })
        |> Repo.update!()
    end

    new_progress = clear_stage_progress(state.progress, event.item_id, event.stage_id)
    {:noreply, %{state | progress: new_progress}}
  end

  @impl true
  def handle_info(%StageSnoozed{} = event, state) do
    now = DateTime.utc_now()

    StageExecution
    |> where(
      [s],
      s.item_id == ^event.item_id and s.stage == ^event.stage_id and s.status == "started"
    )
    |> order_by([s], desc: s.started_at)
    |> limit(1)
    |> Repo.one()
    |> case do
      nil ->
        :ok

      execution ->
        execution
        |> StageExecution.changeset(%{
          status: "snoozed",
          ended_at: now,
          snooze_reason: event.reason
        })
        |> Repo.update!()
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(%StageProgress{} = event, state) do
    new_progress =
      state.progress
      |> Map.put_new(event.item_id, %{})
      |> put_in([event.item_id, event.stage_id], %{
        progress: event.progress,
        message: event.message
      })

    {:noreply, %{state | progress: new_progress}}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call({:get_progress, item_id}, _from, state) do
    progress = Map.get(state.progress, item_id, %{})
    {:reply, progress, state}
  end

  defp clear_stage_progress(progress, item_id, stage_id) do
    case Map.get(progress, item_id) do
      nil ->
        progress

      item_progress ->
        updated = Map.delete(item_progress, stage_id)

        if updated == %{} do
          Map.delete(progress, item_id)
        else
          Map.put(progress, item_id, updated)
        end
    end
  end
end
