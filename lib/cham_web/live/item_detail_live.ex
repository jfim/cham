defmodule ChamWeb.ItemDetailLive do
  use ChamWeb, :live_view

  alias Cham.Items
  alias Cham.JobTracking.Tracker

  @impl true
  def mount(%{"id" => id} = params, _session, socket) do
    item = Items.get_item!(id)
    artifacts = Items.list_artifacts(item.id)
    stage_history = Tracker.get_stage_history(item.id)
    progress = Tracker.get_progress(item.id)

    if connected?(socket) do
      Cham.EventBus.subscribe("pipeline")
      Cham.EventBus.subscribe("item")
    end

    return_path = build_return_path(params)

    {:ok,
     socket
     |> assign(:page_title, item.title || "Item Detail")
     |> assign(:item, item)
     |> assign(:artifacts, artifacts)
     |> assign(:stage_history, stage_history)
     |> assign(:progress, progress)
     |> assign(:return_path, return_path)
     |> assign(:active_tab, nil)
     |> assign_content(item, artifacts, stage_history)}
  end

  @impl true
  def handle_event("select_tab", %{"tab" => tab}, socket) do
    new_tab = if socket.assigns.active_tab == tab, do: nil, else: tab
    {:noreply, assign(socket, :active_tab, new_tab)}
  end

  @impl true
  def handle_info(event, socket) do
    item_id = socket.assigns.item.id

    if event_for_item?(event, item_id) do
      item = Items.get_item!(item_id)
      artifacts = Items.list_artifacts(item_id)
      stage_history = Tracker.get_stage_history(item_id)
      progress = Tracker.get_progress(item_id)

      {:noreply,
       socket
       |> assign(:item, item)
       |> assign(:artifacts, artifacts)
       |> assign(:stage_history, stage_history)
       |> assign(:progress, progress)
       |> assign_content(item, artifacts, stage_history)}
    else
      {:noreply, socket}
    end
  end

  defp build_return_path(params) do
    query =
      %{}
      |> then(fn q ->
        if params["return_type"], do: Map.put(q, "type", params["return_type"]), else: q
      end)
      |> then(fn q ->
        if params["return_tag"], do: Map.put(q, "tag", params["return_tag"]), else: q
      end)

    if query == %{}, do: ~p"/", else: ~p"/?#{query}"
  end

  defp assign_content(socket, item, artifacts, stage_history) do
    socket
    |> assign(:primary_content, resolve_primary_content(item, artifacts, stage_history))
    |> assign(:summary, resolve_artifact_content(item, artifacts, stage_history, "summary"))
    |> assign(:transcript, resolve_artifact_content(item, artifacts, stage_history, "transcript"))
    |> assign(:metadata_json, Jason.encode!(item.metadata || %{}, pretty: true))
  end

  defp resolve_primary_content(item, artifacts, stage_history) do
    case item.content_type do
      "article" -> resolve_artifact_content(item, artifacts, stage_history, "text", "original")
      "video" -> resolve_artifact_content(item, artifacts, stage_history, "transcript")
      _ -> %{state: :not_requested, content: nil, error: nil}
    end
  end

  defp resolve_artifact_content(item, artifacts, stage_history, type, origin \\ "derived") do
    artifact =
      Enum.find(artifacts, fn a ->
        a.labels["type"] == type && a.labels["origin"] == origin && a.status == "produced"
      end)

    cond do
      artifact ->
        case Items.read_artifact_content(item, artifact) do
          {:ok, content} -> %{state: :available, content: content, error: nil}
          {:error, _} -> %{state: :available, content: "[Could not read file]", error: nil}
        end

      has_running_stage?(stage_history, type) ->
        %{state: :processing, content: nil, error: nil}

      failed_stage = find_failed_stage(stage_history, type) ->
        %{state: :failed, content: nil, error: failed_stage.error}

      true ->
        %{state: :not_requested, content: nil, error: nil}
    end
  end

  defp has_running_stage?(stage_history, type) do
    Enum.any?(stage_history, fn s ->
      s.status == "started" && String.contains?(s.stage, type)
    end)
  end

  defp find_failed_stage(stage_history, type) do
    Enum.find(stage_history, fn s ->
      s.status == "failed" && String.contains?(s.stage, type)
    end)
  end

  defp event_for_item?(%{item_id: event_item_id}, item_id), do: event_item_id == item_id
  defp event_for_item?(%{item: %{id: event_item_id}}, item_id), do: event_item_id == item_id
  defp event_for_item?(_, _), do: false

  defp is_processing?(item), do: item.status in ["bootstrapping", "processing"]

  defp tabs_for(item) do
    case item.content_type do
      type when type in ["video", "podcast"] ->
        ["summary", "transcript", "metadata", "chat", "actions"]

      _ ->
        ["summary", "metadata", "chat", "actions"]
    end
  end

  defp tab_label("summary"), do: "Summary"
  defp tab_label("transcript"), do: "Transcript"
  defp tab_label("metadata"), do: "Metadata"
  defp tab_label("chat"), do: "Chat"
  defp tab_label("actions"), do: "Actions"
  defp tab_label(other), do: String.capitalize(other)
end
