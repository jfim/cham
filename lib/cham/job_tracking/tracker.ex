defmodule Cham.JobTracking.Tracker do
  use GenServer

  alias Cham.Repo
  alias Cham.JobTracking.StageExecution

  alias Cham.Pipeline.Events.{
    StageStarted,
    StageCompleted,
    StageFailed,
    StageSnoozed,
    StageProgress
  }

  import Ecto.Query

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
    Cham.EventBus.subscribe("pipeline")
    {:ok, %{progress: %{}}}
  end

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
