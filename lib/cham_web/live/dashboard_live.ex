defmodule ChamWeb.DashboardLive do
  use ChamWeb, :live_view

  alias Cham.Items
  alias Cham.Pipeline

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Cham.EventBus.subscribe("item")
    end

    socket =
      socket
      |> assign(:page_title, "Dashboard")
      |> assign(:show_in_progress, false)
      |> assign(:show_submit_modal, false)
      |> assign(:submit_error, nil)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    active_type = Map.get(params, "type")
    active_tag = Map.get(params, "tag")

    filters =
      []
      |> then(fn f -> if active_type, do: [{:content_type, active_type} | f], else: f end)
      |> then(fn f -> if active_tag, do: [{:tag, active_tag} | f], else: f end)

    items = Items.list_items(filters)
    in_progress = Items.list_in_progress_items()
    type_counts = Items.count_by_content_type()
    tag_counts = Items.count_by_tag()

    active_count =
      Enum.count(in_progress, fn item -> item.status in ["bootstrapping", "processing"] end)

    total_count = length(Items.list_items([]))

    socket =
      socket
      |> assign(:items, items)
      |> assign(:in_progress, in_progress)
      |> assign(:active_type, active_type)
      |> assign(:active_tag, active_tag)
      |> assign(:type_counts, type_counts)
      |> assign(:tag_counts, tag_counts)
      |> assign(:active_count, active_count)
      |> assign(:total_count, total_count)

    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_in_progress", _params, socket) do
    {:noreply, assign(socket, :show_in_progress, !socket.assigns.show_in_progress)}
  end

  def handle_event("filter_type", %{"type" => type}, socket) do
    new_type = if type == socket.assigns.active_type, do: nil, else: type

    params =
      %{}
      |> then(fn p -> if new_type, do: Map.put(p, "type", new_type), else: p end)
      |> then(fn p ->
        if socket.assigns.active_tag,
          do: Map.put(p, "tag", socket.assigns.active_tag),
          else: p
      end)

    {:noreply, push_patch(socket, to: ~p"/?#{params}")}
  end

  def handle_event("filter_tag", %{"tag" => tag}, socket) do
    new_tag = if tag == socket.assigns.active_tag, do: nil, else: tag

    params =
      %{}
      |> then(fn p -> if new_tag, do: Map.put(p, "tag", new_tag), else: p end)
      |> then(fn p ->
        if socket.assigns.active_type,
          do: Map.put(p, "type", socket.assigns.active_type),
          else: p
      end)

    {:noreply, push_patch(socket, to: ~p"/?#{params}")}
  end

  def handle_event("submit_url", %{"url" => url}, socket) do
    case Pipeline.submit_url(url) do
      {:ok, _item} ->
        {:noreply,
         socket
         |> put_flash(:info, "URL submitted for processing")
         |> push_navigate(to: ~p"/")}

      {:error, changeset} ->
        error_msg =
          changeset
          |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
          |> Enum.map_join(", ", fn {_field, msgs} -> Enum.join(msgs, ", ") end)

        {:noreply, assign(socket, :submit_error, error_msg)}
    end
  end

  @impl true
  def handle_info(_event, socket) do
    in_progress = Items.list_in_progress_items()
    active_count = Enum.count(in_progress, &(&1.status in ["bootstrapping", "processing"]))
    type_counts = Items.count_by_content_type()
    tag_counts = Items.count_by_tag()

    filters =
      []
      |> then(fn f ->
        if socket.assigns.active_type,
          do: [{:content_type, socket.assigns.active_type} | f],
          else: f
      end)
      |> then(fn f ->
        if socket.assigns.active_tag, do: [{:tag, socket.assigns.active_tag} | f], else: f
      end)

    items = Items.list_items(filters)

    {:noreply,
     socket
     |> assign(:in_progress, in_progress)
     |> assign(:active_count, active_count)
     |> assign(:type_counts, type_counts)
     |> assign(:tag_counts, tag_counts)
     |> assign(:items, items)
     |> assign(:total_count, length(items))}
  end

  defp hero_text(assigns) do
    cond do
      assigns.active_type && assigns.active_tag ->
        "Showing #{content_type_label(assigns.active_type)} tagged \"#{assigns.active_tag}\""

      assigns.active_type ->
        "Showing #{content_type_label(assigns.active_type)}"

      assigns.active_tag ->
        "Showing items tagged \"#{assigns.active_tag}\""

      assigns.total_count == 0 ->
        "Cham knows about nothing yet"

      true ->
        "Cham knows about #{assigns.total_count} pieces of information"
    end
  end

  defp truncate_url(nil), do: ""

  defp truncate_url(url) do
    case URI.parse(url) do
      %URI{host: host, path: path} when is_binary(host) ->
        display = (host || "") <> (path || "")

        if String.length(display) > 50 do
          String.slice(display, 0, 47) <> "..."
        else
          display
        end

      _ ->
        if String.length(url) > 50 do
          String.slice(url, 0, 47) <> "..."
        else
          url
        end
    end
  end

  defp return_params(assigns) do
    %{}
    |> then(fn p ->
      if assigns.active_type, do: Map.put(p, "return_type", assigns.active_type), else: p
    end)
    |> then(fn p ->
      if assigns.active_tag, do: Map.put(p, "return_tag", assigns.active_tag), else: p
    end)
  end

  defp content_type_label(type) do
    case type do
      "article" -> "Articles"
      "video" -> "Videos"
      "document" -> "Documents"
      "podcast" -> "Podcasts"
      _ -> String.capitalize(type || "Items") <> "s"
    end
  end

  defp content_type_icon(type) do
    case type do
      "article" -> "hero-document-text"
      "video" -> "hero-play-circle"
      "document" -> "hero-document"
      "podcast" -> "hero-microphone"
      _ -> "hero-document"
    end
  end
end
