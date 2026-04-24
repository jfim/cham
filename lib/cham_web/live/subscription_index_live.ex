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

  def handle_event("poll_now", %{"id" => id}, socket) do
    sub = Subscriptions.get_subscription!(id)
    {:ok, _} = Subscriptions.enqueue_poll(sub)

    {:noreply,
     socket
     |> put_flash(:info, "Polling \"#{sub.title}\" now…")
     |> assign(:subscriptions, Subscriptions.list_subscriptions())}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    sub = Subscriptions.get_subscription!(id)
    {:ok, _} = Subscriptions.delete_subscription(sub)
    {:noreply, assign(socket, :subscriptions, Subscriptions.list_subscriptions())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-50">
      <div class="bg-white border-b border-gray-200 px-8 py-4">
        <div class="flex items-center justify-between">
          <.link
            navigate={~p"/"}
            class="text-sm text-gray-500 hover:text-gray-700 flex items-center gap-1"
          >
            <ChamWeb.CoreComponents.icon name="hero-arrow-left-mini" class="h-4 w-4" />
            Back to archive
          </.link>
        </div>
      </div>

      <main class="max-w-6xl mx-auto px-8 py-8 overflow-x-auto">
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
              <tr id={"sub-#{sub.id}"} class="border-b align-top">
                <td class="py-2 pr-4">
                  <.link navigate={~p"/subscriptions/#{sub.id}"}>{sub.title}</.link>
                </td>
                <td class="py-2 pr-4 text-sm">{sub.source_url}</td>
                <td class="py-2 pr-4">{sub.backend}</td>
                <td class="py-2 pr-4 text-sm">{format_ts(sub.last_polled_at)}</td>
                <td class="py-2 pr-4">{format_interval(sub.poll_interval_seconds)}</td>
                <td class="py-2 pr-4 max-w-md">
                  <%= cond do %>
                    <% not sub.active -> %>
                      <span class="text-gray-500">paused</span>
                    <% sub.consecutive_failures > @failure_threshold -> %>
                      <div class="text-red-600">
                        <div class="font-medium">
                          Last {sub.consecutive_failures} polls failed
                        </div>
                        <div :if={sub.last_error} class="text-xs text-red-700 mt-0.5 break-words">
                          {sub.last_error}
                        </div>
                      </div>
                    <% sub.consecutive_failures > 0 -> %>
                      <div class="text-amber-600">
                        <div class="font-medium">
                          {sub.consecutive_failures} recent {failure_noun(sub.consecutive_failures)}
                        </div>
                        <div :if={sub.last_error} class="text-xs text-amber-700 mt-0.5 break-words">
                          {sub.last_error}
                        </div>
                      </div>
                    <% true -> %>
                      <span class="text-green-600">ok</span>
                  <% end %>
                </td>
                <td class="py-2">
                  <div class="flex items-center gap-1">
                    <button
                      type="button"
                      phx-click="poll_now"
                      phx-value-id={sub.id}
                      title="Poll now"
                      aria-label="Poll now"
                      class="p-1.5 rounded hover:bg-gray-200 text-gray-700"
                    >
                      <ChamWeb.CoreComponents.icon name="hero-arrow-path" class="h-4 w-4" />
                    </button>
                    <button
                      type="button"
                      phx-click="toggle_active"
                      phx-value-id={sub.id}
                      title={if sub.active, do: "Pause", else: "Resume"}
                      aria-label={if sub.active, do: "Pause", else: "Resume"}
                      class="p-1.5 rounded hover:bg-gray-200 text-gray-700"
                    >
                      <ChamWeb.CoreComponents.icon
                        name={if sub.active, do: "hero-pause", else: "hero-play"}
                        class="h-4 w-4"
                      />
                    </button>
                    <button
                      type="button"
                      phx-click="delete"
                      phx-value-id={sub.id}
                      data-confirm="Delete this subscription?"
                      title="Delete"
                      aria-label="Delete"
                      class="p-1.5 rounded hover:bg-red-100 text-red-600"
                    >
                      <ChamWeb.CoreComponents.icon name="hero-trash" class="h-4 w-4" />
                    </button>
                  </div>
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
      </main>
    </div>
    """
  end

  defp failure_noun(1), do: "failure"
  defp failure_noun(_), do: "failures"

  defp format_ts(nil), do: "—"
  defp format_ts(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")

  defp format_interval(sec) when sec >= 86_400, do: "#{div(sec, 86_400)}d"
  defp format_interval(sec) when sec >= 3600, do: "#{div(sec, 3600)}h"
  defp format_interval(sec), do: "#{sec}s"
end
