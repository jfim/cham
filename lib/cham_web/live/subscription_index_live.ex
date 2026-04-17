defmodule ChamWeb.SubscriptionIndexLive do
  use ChamWeb, :live_view

  alias Cham.Subscriptions

  @failure_threshold 5

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:subscriptions, Subscriptions.list_subscriptions())
     |> assign(:failure_threshold, @failure_threshold)}
  end

  @impl true
  def handle_event("toggle_active", %{"id" => id}, socket) do
    sub = Subscriptions.get_subscription!(id)
    {:ok, _} = Subscriptions.update_subscription(sub, %{active: not sub.active})
    {:noreply, assign(socket, :subscriptions, Subscriptions.list_subscriptions())}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    sub = Subscriptions.get_subscription!(id)
    {:ok, _} = Subscriptions.delete_subscription(sub)
    {:noreply, assign(socket, :subscriptions, Subscriptions.list_subscriptions())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-6">
      <h1 class="text-2xl font-bold mb-4">Subscriptions</h1>

      <table class="w-full text-left">
        <thead>
          <tr class="border-b">
            <th class="py-2 pr-4">Title</th>
            <th class="py-2 pr-4">Source</th>
            <th class="py-2 pr-4">Backend</th>
            <th class="py-2 pr-4">Last poll</th>
            <th class="py-2 pr-4">Interval</th>
            <th class="py-2 pr-4">Status</th>
            <th class="py-2"></th>
          </tr>
        </thead>
        <tbody>
          <%= for sub <- @subscriptions do %>
            <tr id={"sub-#{sub.id}"} class="border-b">
              <td class="py-2 pr-4">
                <.link navigate={~p"/subscriptions/#{sub.id}"}>{sub.title}</.link>
              </td>
              <td class="py-2 pr-4 text-sm">{sub.source_url}</td>
              <td class="py-2 pr-4">{sub.backend}</td>
              <td class="py-2 pr-4 text-sm">{format_ts(sub.last_polled_at)}</td>
              <td class="py-2 pr-4">{format_interval(sub.poll_interval_seconds)}</td>
              <td class="py-2 pr-4">
                <%= cond do %>
                  <% not sub.active -> %>
                    <span class="text-gray-500">paused</span>
                  <% sub.consecutive_failures > @failure_threshold -> %>
                    <span class="text-red-600">
                      Last {sub.consecutive_failures} polls failed: {sub.last_error}
                    </span>
                  <% true -> %>
                    <span class="text-green-600">ok</span>
                <% end %>
              </td>
              <td class="py-2">
                <button phx-click="toggle_active" phx-value-id={sub.id} class="underline">
                  {if sub.active, do: "Pause", else: "Resume"}
                </button>
                <button
                  phx-click="delete"
                  phx-value-id={sub.id}
                  data-confirm="Delete this subscription?"
                  class="underline text-red-600 ml-2"
                >
                  Delete
                </button>
              </td>
            </tr>
          <% end %>
          <%= if @subscriptions == [] do %>
            <tr>
              <td colspan="7" class="py-4 text-gray-500 text-center">
                No subscriptions yet.
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end

  defp format_ts(nil), do: "—"
  defp format_ts(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")

  defp format_interval(sec) when sec >= 86_400, do: "#{div(sec, 86_400)}d"
  defp format_interval(sec) when sec >= 3600, do: "#{div(sec, 3600)}h"
  defp format_interval(sec), do: "#{sec}s"
end
