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

    live "/", DashboardLive
    live "/items/:id", ItemDetailLive
    live "/config", ConfigLive
  end

  scope "/api/v1", ChamWeb do
    pipe_through :api

    resources "/items", ItemController, only: [:create, :index, :show, :delete]
    post "/items/:id/reprocess", ItemController, :reprocess
    post "/items/:id/cancel", ItemController, :cancel
    post "/items/:id/retry", ItemController, :retry
    get "/items/:id/events", EventController, :stream
  end

  scope "/api/v1", ChamWeb do
    get "/items/:id/files/*filename", FileController, :show
  end

  scope "/", ChamWeb do
    pipe_through :api
    get "/health", HealthController, :index
  end
end
