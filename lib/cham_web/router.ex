defmodule ChamWeb.Router do
  use ChamWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ChamWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", ChamWeb do
    pipe_through :browser

    live "/config", ConfigLive
    live "/subscriptions", SubscriptionIndexLive
  end

  scope "/", ChamWeb do
    pipe_through :api
    get "/health", HealthController, :index
  end

  scope "/mcp" do
    pipe_through :api
    forward "/", Anubis.Server.Transport.StreamableHTTP.Plug, server: Cham.MCP.Server
  end

  if Application.compile_env(:cham, :dev_routes, Mix.env() == :dev) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard",
        metrics: ChamWeb.Telemetry,
        ecto_repos: [Cham.Repo],
        ecto_psql_extras_options: [long_running_queries: [threshold: "200 milliseconds"]]
    end
  end
end
