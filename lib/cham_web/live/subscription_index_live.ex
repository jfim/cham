defmodule ChamWeb.SubscriptionIndexLive do
  use ChamWeb, :live_view

  alias Cham.Subscriptions

  @failure_threshold 5

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Subscriptions")
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
    <div style="min-height: 100vh; background: var(--cham-surface-page);">
      <div class="item-topbar">
        <.link
          navigate={~p"/"}
          class="iconbtn"
          style="display: inline-flex; align-items: center; gap: 6px; text-decoration: none; padding: 4px 8px; font-size: var(--cham-text-sm); color: var(--cham-fg-muted);"
        >
          <ChamWeb.CoreComponents.icon name="hero-arrow-left-mini" class="h-4 w-4" /> Back to archive
        </.link>
      </div>

      <main style="max-width: 64rem; margin: 0 auto; padding: var(--cham-space-12) var(--cham-space-8) var(--cham-space-8); overflow-x: auto;">
        <h1 style="font: var(--cham-fw-normal) var(--cham-text-3xl)/1.2 var(--cham-font-display); color: var(--cham-fg-strong); letter-spacing: var(--cham-track-tight); margin: 0 0 var(--cham-space-6);">
          Subscriptions
        </h1>

        <table style="width: 100%; text-align: left; border-collapse: collapse; font-size: var(--cham-text-sm); color: var(--cham-fg);">
          <thead>
            <tr style="border-bottom: 1px solid var(--cham-border-subtle);">
              <th style="padding: var(--cham-space-2) var(--cham-space-3) var(--cham-space-2) 0; font: var(--cham-fw-semibold) 11px/1 var(--cham-font-ui); color: var(--cham-fg-faint); text-transform: uppercase; letter-spacing: var(--cham-track-wider);">
                Title
              </th>
              <th style="padding: var(--cham-space-2) var(--cham-space-3) var(--cham-space-2) 0; font: var(--cham-fw-semibold) 11px/1 var(--cham-font-ui); color: var(--cham-fg-faint); text-transform: uppercase; letter-spacing: var(--cham-track-wider);">
                Source
              </th>
              <th style="padding: var(--cham-space-2) var(--cham-space-3) var(--cham-space-2) 0; font: var(--cham-fw-semibold) 11px/1 var(--cham-font-ui); color: var(--cham-fg-faint); text-transform: uppercase; letter-spacing: var(--cham-track-wider);">
                Backend
              </th>
              <th style="padding: var(--cham-space-2) var(--cham-space-3) var(--cham-space-2) 0; font: var(--cham-fw-semibold) 11px/1 var(--cham-font-ui); color: var(--cham-fg-faint); text-transform: uppercase; letter-spacing: var(--cham-track-wider);">
                Last poll
              </th>
              <th style="padding: var(--cham-space-2) var(--cham-space-3) var(--cham-space-2) 0; font: var(--cham-fw-semibold) 11px/1 var(--cham-font-ui); color: var(--cham-fg-faint); text-transform: uppercase; letter-spacing: var(--cham-track-wider);">
                Interval
              </th>
              <th style="padding: var(--cham-space-2) var(--cham-space-3) var(--cham-space-2) 0; font: var(--cham-fw-semibold) 11px/1 var(--cham-font-ui); color: var(--cham-fg-faint); text-transform: uppercase; letter-spacing: var(--cham-track-wider);">
                Status
              </th>
              <th style="padding: var(--cham-space-2) 0;"></th>
            </tr>
          </thead>
          <tbody>
            <%= for sub <- @subscriptions do %>
              <tr
                id={"sub-#{sub.id}"}
                style="border-bottom: 1px solid var(--cham-border-subtle); vertical-align: top;"
              >
                <td style="padding: var(--cham-space-3) var(--cham-space-3) var(--cham-space-3) 0;">
                  <.link
                    navigate={~p"/subscriptions/#{sub.id}"}
                    style="font: var(--cham-fw-semibold) var(--cham-text-base)/1.3 var(--cham-font-display); color: var(--cham-fg-strong); letter-spacing: var(--cham-track-tight); text-decoration: none;"
                  >
                    {sub.title}
                  </.link>
                </td>
                <td style="padding: var(--cham-space-3) var(--cham-space-3) var(--cham-space-3) 0; font-family: var(--cham-font-mono); font-size: var(--cham-text-xs); color: var(--cham-fg-soft); word-break: break-all;">
                  {sub.source_url}
                </td>
                <td style="padding: var(--cham-space-3) var(--cham-space-3) var(--cham-space-3) 0; font-family: var(--cham-font-mono); font-size: var(--cham-text-xs); color: var(--cham-fg-muted);">
                  {sub.backend}
                </td>
                <td style="padding: var(--cham-space-3) var(--cham-space-3) var(--cham-space-3) 0; font-family: var(--cham-font-mono); font-size: var(--cham-text-xs); color: var(--cham-fg-soft); font-variant-numeric: tabular-nums;">
                  {format_ts(sub.last_polled_at)}
                </td>
                <td style="padding: var(--cham-space-3) var(--cham-space-3) var(--cham-space-3) 0; font-family: var(--cham-font-mono); font-size: var(--cham-text-xs); color: var(--cham-fg-muted); font-variant-numeric: tabular-nums;">
                  {format_interval(sub.poll_interval_seconds)}
                </td>
                <td style="padding: var(--cham-space-3) var(--cham-space-3) var(--cham-space-3) 0; max-width: 28rem;">
                  <%= cond do %>
                    <% not sub.active -> %>
                      <span class="stage-badge is-info">paused</span>
                    <% sub.consecutive_failures > @failure_threshold -> %>
                      <div>
                        <span class="stage-badge is-fail">
                          Last {sub.consecutive_failures} polls failed
                        </span>
                        <div
                          :if={sub.last_error}
                          style="margin-top: 4px; font-size: var(--cham-text-xs); color: var(--cham-stage-fail-fg); font-family: var(--cham-font-mono); word-break: break-word;"
                        >
                          {sub.last_error}
                        </div>
                      </div>
                    <% sub.consecutive_failures > 0 -> %>
                      <div>
                        <span class="stage-badge is-active">
                          {sub.consecutive_failures} recent {failure_noun(sub.consecutive_failures)}
                        </span>
                        <div
                          :if={sub.last_error}
                          style="margin-top: 4px; font-size: var(--cham-text-xs); color: var(--cham-stage-active-fg); font-family: var(--cham-font-mono); word-break: break-word;"
                        >
                          {sub.last_error}
                        </div>
                      </div>
                    <% true -> %>
                      <span class="stage-badge is-done">ok</span>
                  <% end %>
                </td>
                <td style="padding: var(--cham-space-3) 0;">
                  <div style="display: flex; align-items: center; gap: 2px;">
                    <button
                      type="button"
                      phx-click="poll_now"
                      phx-value-id={sub.id}
                      title="Poll now"
                      aria-label="Poll now"
                      class="iconbtn"
                    >
                      <ChamWeb.CoreComponents.icon name="hero-arrow-path" class="h-4 w-4" />
                    </button>
                    <button
                      type="button"
                      phx-click="toggle_active"
                      phx-value-id={sub.id}
                      title={if sub.active, do: "Pause", else: "Resume"}
                      aria-label={if sub.active, do: "Pause", else: "Resume"}
                      class="iconbtn"
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
                      class="iconbtn"
                      style="color: var(--cham-stage-fail-fg);"
                    >
                      <ChamWeb.CoreComponents.icon name="hero-trash" class="h-4 w-4" />
                    </button>
                  </div>
                </td>
              </tr>
            <% end %>
            <%= if @subscriptions == [] do %>
              <tr>
                <td
                  colspan="7"
                  style="padding: var(--cham-space-12) 0; text-align: center; color: var(--cham-fg-soft); font-size: var(--cham-text-sm);"
                >
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
