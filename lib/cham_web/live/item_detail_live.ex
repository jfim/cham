defmodule ChamWeb.ItemDetailLive do
  use ChamWeb, :live_view

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    {:ok, assign(socket, :item_id, id)}
  end
end
