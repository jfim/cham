defmodule Cham.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        ChamWeb.Telemetry,
        Cham.Repo,
        {Oban, Application.fetch_env!(:cham, Oban)},
        {DNSCluster, query: Application.get_env(:cham, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Cham.PubSub},
        {Cham.Config.Manager,
         toml_path: Application.get_env(:cham, :config_toml_path, "config/cham.toml"),
         event_bus: Cham.PubSub}
      ] ++
        tracker_children() ++
        [
          # Start to serve requests, typically the last entry
          ChamWeb.Endpoint
        ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Cham.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  defp tracker_children do
    if Application.get_env(:cham, :start_tracker, true) do
      [Cham.JobTracking.Tracker]
    else
      []
    end
  end

  @impl true
  def config_change(changed, _new, removed) do
    ChamWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
