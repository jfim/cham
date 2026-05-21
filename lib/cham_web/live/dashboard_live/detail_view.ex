defmodule ChamWeb.DashboardLive.DetailView do
  @moduledoc false

  use Phoenix.Component
  use ChamWeb, :verified_routes

  import Phoenix.HTML
  import ChamWeb.CoreComponents
  alias Phoenix.LiveView.JS
  import ChamWeb.UIComponents
  import ChamWeb.DashboardLive.DetailHelpers

  embed_templates "detail_view/*"
end
