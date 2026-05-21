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

    live "/", DashboardLive, :index
    live "/items/:id", DashboardLive, :detail
    live "/config", ConfigLive
    live "/subscriptions", SubscriptionIndexLive
    live "/subscriptions/:id", SubscriptionShowLive
  end

  scope "/api/v1", ChamWeb do
    pipe_through :api

    resources "/items", ItemController, only: [:create, :index, :show, :delete]
    post "/items/:id/reprocess", ItemController, :reprocess
    post "/items/:id/cancel", ItemController, :cancel
    post "/items/:id/retry", ItemController, :retry
    get "/items/:id/events", EventController, :stream

    post "/tags/clear", TagController, :clear
  end

  scope "/api/v1", ChamWeb do
    get "/items/:id/files/*filename", FileController, :show
  end

  scope "/", ChamWeb do
    pipe_through :api
    get "/health", HealthController, :index
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
