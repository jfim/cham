defmodule Cham.Pipeline.Supervisor do
  @moduledoc """
  Supervises the processing pipeline subtree: Oban, the Orchestrator, the
  job Tracker, and the QueueScaler.

  Isolated from the top-level supervisor so a crash-looping orchestrator
  degrades item processing without taking the web UI or the database
  pool down with it. When this subtree exhausts its restart budget it
  shuts down on its own; the rest of the application keeps serving.
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children =
      [{Oban, Application.fetch_env!(:cham, Oban)}] ++
        orchestrator_children() ++
        tracker_children() ++
        queue_scaler_children()

    Supervisor.init(children, strategy: :one_for_one, max_restarts: 10, max_seconds: 60)
  end

  defp orchestrator_children do
    if Application.get_env(:cham, :start_orchestrator, true),
      do: [Cham.Pipeline.Orchestrator],
      else: []
  end

  defp tracker_children do
    if Application.get_env(:cham, :start_tracker, true),
      do: [Cham.JobTracking.Tracker],
      else: []
  end

  defp queue_scaler_children do
    if Application.get_env(:cham, :start_queue_scaler, true),
      do: [Cham.Pipeline.QueueScaler],
      else: []
  end
end
