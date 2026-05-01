defmodule Cham.Subscriptions.Supervisor do
  @moduledoc """
  Supervises the subscriptions subtree.

  Isolated from the top-level supervisor so subscription failures don't
  cascade into the rest of the app. Currently holds the backend registry;
  future subscription processes (pollers, workers with long-lived state)
  belong here too.
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Cham.Subscriptions.BackendRegistry, []}
    ]

    Supervisor.init(children, strategy: :one_for_one, max_restarts: 10, max_seconds: 60)
  end
end
