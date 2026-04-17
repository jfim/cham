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
    <div class="p-6 max-w-4xl">
      <h1 class="text-2xl font-bold mb-2">{@subscription.title}</h1>
      <p class="text-sm text-gray-500 mb-6">{@subscription.source_url}</p>

      <section id="settings" class="mb-8">
        <h2 class="text-lg font-semibold mb-2">Settings</h2>
        <.form
          for={%{}}
          as={:subscription}
          id="settings-form"
          phx-submit="update_settings"
          class="space-y-2"
        >
          <div>
            <label class="block text-sm">Title</label>
            <input
              name="subscription[title]"
              value={@subscription.title}
              class="border px-2 py-1 w-full"
            />
          </div>
          <div>
            <label class="block text-sm">Poll interval</label>
            <select name="subscription[poll_interval_seconds]" class="border px-2 py-1">
              <option value="3600" selected={@subscription.poll_interval_seconds == 3600}>1 hour</option>
              <option value="21600" selected={@subscription.poll_interval_seconds == 21600}>6 hours</option>
              <option value="86400" selected={@subscription.poll_interval_seconds == 86400}>24 hours</option>
            </select>
          </div>
          <div>
            <label class="inline-flex items-center gap-2 text-sm">
              <input
                type="hidden"
                name="subscription[active]"
                value="false"
              />
              <input
                type="checkbox"
                name="subscription[active]"
                value="true"
                checked={@subscription.active}
              />
              Active
            </label>
          </div>
          <button type="submit" class="bg-blue-600 text-white px-3 py-1 rounded">Save</button>
        </.form>
      </section>

      <section class="mb-8">
        <h2 class="text-lg font-semibold mb-2">Re-run backfill</h2>
        <.form for={%{}} phx-submit="backfill" class="space-y-2">
          <div>
            <label class="inline-flex items-center gap-2">
              <input type="radio" name="mode" value="last_n" /> Last
              <input name="n" value="10" type="number" class="border px-2 py-1 w-20" />
              items
            </label>
          </div>
          <div>
            <label class="inline-flex items-center gap-2">
              <input type="radio" name="mode" value="since" /> Since
              <input name="date" type="date" class="border px-2 py-1" />
            </label>
          </div>
          <button type="submit" class="bg-blue-600 text-white px-3 py-1 rounded">Run</button>
        </.form>
      </section>

      <section>
        <h2 class="text-lg font-semibold mb-2">Items</h2>
        <ul class="space-y-1">
          <%= for item <- @items do %>
            <li>
              <.link navigate={~p"/items/#{item.id}"} class="underline">
                {item.title || item.url}
              </.link>
            </li>
          <% end %>
          <%= if @items == [] do %>
            <li class="text-gray-500">No items yet.</li>
          <% end %>
        </ul>
      </section>
    </div>
    """
  end
end
