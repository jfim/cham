defmodule ChamWeb.SubscriptionShowLive do
  use ChamWeb, :live_view

  import Ecto.Query

  alias Cham.Repo
  alias Cham.Subscriptions
  alias Cham.Items.Item

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    sub = Subscriptions.get_subscription!(id)

    items =
      Repo.all(
        from i in Item,
          where: i.subscription_id == ^id,
          order_by: [desc: i.inserted_at],
          limit: 200
      )

    {:ok,
     socket
     |> assign(:page_title, sub.title || "Subscription")
     |> assign(:subscription, sub)
     |> assign(:items, items)}
  end

  @impl true
  def handle_event("update_settings", %{"subscription" => attrs}, socket) do
    normalized =
      attrs
      |> Map.update("poll_interval_seconds", nil, fn
        nil -> nil
        v when is_binary(v) -> String.to_integer(v)
        v -> v
      end)
      |> Map.update("active", false, fn
        "true" -> true
        true -> true
        _ -> false
      end)

    case Subscriptions.update_subscription(socket.assigns.subscription, normalized) do
      {:ok, sub} ->
        {:noreply,
         socket
         |> assign(:subscription, sub)
         |> put_flash(:info, "Settings saved")}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, "Save failed: #{inspect(changeset.errors)}")}
    end
  end

  def handle_event("backfill", %{"mode" => mode} = params, socket) do
    backfill =
      case mode do
        "none" ->
          "none"

        "last_n" ->
          %{"mode" => "last_n", "n" => String.to_integer(params["n"] || "10")}

        "since" ->
          date = params["date"] <> "T00:00:00Z"
          %{"mode" => "since", "date" => date}
      end

    %{"subscription_id" => socket.assigns.subscription.id, "backfill" => backfill}
    |> Cham.Subscriptions.PollWorker.new()
    |> Oban.insert()

    {:noreply, put_flash(socket, :info, "Backfill poll enqueued")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div style="min-height: 100vh; background: var(--cham-surface-page);">
      <div class="item-topbar">
        <.link
          navigate={~p"/subscriptions"}
          class="iconbtn"
          style="display: inline-flex; align-items: center; gap: 6px; text-decoration: none; padding: 4px 8px; font-size: var(--cham-text-sm); color: var(--cham-fg-muted);"
        >
          <ChamWeb.CoreComponents.icon name="hero-arrow-left-mini" class="h-4 w-4" />
          Back to subscriptions
        </.link>
      </div>
      <main style="max-width: 56rem; margin: 0 auto; padding: var(--cham-space-12) var(--cham-space-8) var(--cham-space-8);">
        <h1 style="font: var(--cham-fw-normal) var(--cham-text-3xl)/1.2 var(--cham-font-display); color: var(--cham-fg-strong); letter-spacing: var(--cham-track-tight); margin: 0 0 var(--cham-space-2);">
          {@subscription.title}
        </h1>
        <p style="font-family: var(--cham-font-mono); font-size: var(--cham-text-xs); color: var(--cham-fg-soft); margin: 0 0 var(--cham-space-6); word-break: break-all;">
          {@subscription.source_url}
        </p>

        <div
          :if={@subscription.last_error && @subscription.consecutive_failures > 0}
          style="margin-bottom: var(--cham-space-6); border-radius: var(--cham-radius-md); background: var(--cham-stage-fail-bg); border: 1px solid var(--cham-stage-fail-fg); padding: var(--cham-space-3) var(--cham-space-4); font-size: var(--cham-text-sm);"
        >
          <div style="font-weight: var(--cham-fw-semibold); color: var(--cham-stage-fail-fg);">
            Last poll failed ({@subscription.consecutive_failures} consecutive {failure_noun(
              @subscription.consecutive_failures
            )})
          </div>
          <div style="margin-top: 4px; color: var(--cham-stage-fail-fg); word-break: break-words; font-family: var(--cham-font-mono); font-size: var(--cham-text-xs);">
            {@subscription.last_error}
          </div>
        </div>

        <section
          id="settings"
          style="margin-bottom: var(--cham-space-8); padding: var(--cham-space-5); border: 1px solid var(--cham-border-subtle); border-radius: var(--cham-radius-md); background: var(--cham-surface);"
        >
          <h2 class="sidebar-eyebrow" style="margin: 0 0 var(--cham-space-4);">Settings</h2>
          <.form
            for={%{}}
            as={:subscription}
            id="settings-form"
            phx-submit="update_settings"
            style="display: flex; flex-direction: column; gap: var(--cham-space-4);"
          >
            <div>
              <label style="display: block; font-size: var(--cham-text-sm); font-weight: var(--cham-fw-medium); color: var(--cham-fg-muted); margin-bottom: 4px;">
                Title
              </label>
              <input
                name="subscription[title]"
                value={@subscription.title}
                class="search-input"
                style="padding: 8px 12px;"
              />
            </div>
            <div>
              <label style="display: block; font-size: var(--cham-text-sm); font-weight: var(--cham-fw-medium); color: var(--cham-fg-muted); margin-bottom: 4px;">
                Poll interval
              </label>
              <select
                name="subscription[poll_interval_seconds]"
                class="search-input"
                style="padding: 8px 12px;"
              >
                <option value="3600" selected={@subscription.poll_interval_seconds == 3600}>
                  1 hour
                </option>
                <option value="21600" selected={@subscription.poll_interval_seconds == 21600}>
                  6 hours
                </option>
                <option value="86400" selected={@subscription.poll_interval_seconds == 86400}>
                  24 hours
                </option>
              </select>
            </div>
            <div>
              <label style="display: inline-flex; align-items: center; gap: 8px; font-size: var(--cham-text-sm); color: var(--cham-fg-muted);">
                <input type="hidden" name="subscription[active]" value="false" />
                <input
                  type="checkbox"
                  name="subscription[active]"
                  value="true"
                  checked={@subscription.active}
                /> Active
              </label>
            </div>
            <div>
              <button type="submit" class="btn btn-primary">Save</button>
            </div>
          </.form>
        </section>

        <section
          style="margin-bottom: var(--cham-space-8); padding: var(--cham-space-5); border: 1px solid var(--cham-border-subtle); border-radius: var(--cham-radius-md); background: var(--cham-surface);"
        >
          <h2 class="sidebar-eyebrow" style="margin: 0 0 var(--cham-space-4);">Re-run backfill</h2>
          <.form
            for={%{}}
            phx-submit="backfill"
            style="display: flex; flex-direction: column; gap: var(--cham-space-3);"
          >
            <label style="display: inline-flex; align-items: center; gap: 8px; font-size: var(--cham-text-sm); color: var(--cham-fg-muted);">
              <input type="radio" name="mode" value="last_n" /> Last
              <input
                name="n"
                value="10"
                type="number"
                style="width: 5rem; padding: 4px 8px; border: 1px solid var(--cham-border-input); border-radius: var(--cham-radius-sm); background: var(--cham-surface); color: var(--cham-fg); font-family: var(--cham-font-ui); font-size: var(--cham-text-sm);"
              /> items
            </label>
            <label style="display: inline-flex; align-items: center; gap: 8px; font-size: var(--cham-text-sm); color: var(--cham-fg-muted);">
              <input type="radio" name="mode" value="since" /> Since
              <input
                name="date"
                type="date"
                style="padding: 4px 8px; border: 1px solid var(--cham-border-input); border-radius: var(--cham-radius-sm); background: var(--cham-surface); color: var(--cham-fg); font-family: var(--cham-font-ui); font-size: var(--cham-text-sm);"
              />
            </label>
            <div>
              <button type="submit" class="btn btn-primary">Run</button>
            </div>
          </.form>
        </section>

        <section>
          <h2 class="sidebar-eyebrow" style="margin: 0 0 var(--cham-space-3);">Items</h2>
          <div :if={@items == []} style="font-size: var(--cham-text-sm); color: var(--cham-fg-soft); padding: var(--cham-space-4) 0;">
            No items yet.
          </div>
          <div :if={@items != []}>
            <.link
              :for={item <- @items}
              navigate={~p"/items/#{item.id}"}
              class="row"
            >
              <div class="row-body">
                <h3 class="row-title">{item.title || item.url}</h3>
                <div :if={item.title} class="row-meta">
                  <span style="font-family: var(--cham-font-mono); overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">
                    {item.url}
                  </span>
                </div>
              </div>
            </.link>
          </div>
        </section>
      </main>
    </div>
    """
  end

  defp failure_noun(1), do: "failure"
  defp failure_noun(_), do: "failures"
end
