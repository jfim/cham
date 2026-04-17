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

    sub =
      if item.subscription_id,
        do: Cham.Subscriptions.get_subscription!(item.subscription_id),
        else: nil

    {:ok,
     socket
     |> assign(:page_title, item.title || "Item Detail")
     |> assign(:item, item)
     |> assign(:subscription, sub)
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

  def handle_event("retry_failed", _params, socket) do
    item = socket.assigns.item

    case Cham.Pipeline.reprocess(item.id, retry_failed: true) do
      {:ok, _} ->
        {:noreply, put_flash(socket, :info, "Retrying failed stages...")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to retry")}
    end
  end

  def handle_event("invalidate_stage", %{"stage" => stage_id}, socket) do
    item = socket.assigns.item

    case Cham.Pipeline.reprocess(item.id, invalidate: [stage_id]) do
      {:ok, _} ->
        {:noreply, put_flash(socket, :info, "Rerunning #{stage_id}...")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to reprocess stage")}
    end
  end

  def handle_event("subscribe", params, socket) do
    item = socket.assigns.item
    attrs = %{}

    attrs =
      if title = params["title"], do: Map.put(attrs, :title, title), else: attrs

    attrs =
      if interval = params["poll_interval_seconds"] do
        case Integer.parse(interval) do
          {n, ""} -> Map.put(attrs, :poll_interval_seconds, n)
          _ -> attrs
        end
      else
        attrs
      end

    case Cham.Subscriptions.subscribe_from_item(item.id, attrs) do
      {:ok, _sub} ->
        {:noreply, put_flash(socket, :info, "Subscribed successfully")}

      {:error, :no_feed_metadata} ->
        {:noreply, put_flash(socket, :error, "No feed metadata found for this item")}

      {:error, changeset} when is_struct(changeset, Ecto.Changeset) ->
        {:noreply, put_flash(socket, :error, "Failed to create subscription")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to subscribe")}
    end
  end

  def handle_event("reprocess_all", _params, socket) do
    item = socket.assigns.item
    stage_ids = socket.assigns.stage_history |> Enum.map(& &1.stage) |> Enum.uniq()

    case Cham.Pipeline.reprocess(item.id, invalidate: stage_ids) do
      {:ok, _} ->
        {:noreply, put_flash(socket, :info, "Reprocessing all stages...")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to reprocess")}
    end
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
       |> assign(:page_title, item.title || "Item Detail")
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
    |> assign(:original_file_url, resolve_original_file_url(item, artifacts))
    |> assign(:metadata_json, build_metadata_json(item))
  end

  defp resolve_primary_content(item, artifacts, stage_history) do
    case item.content_type do
      "article" -> resolve_artifact_content(item, artifacts, stage_history, "content", "original")
      "video" -> resolve_artifact_content(item, artifacts, stage_history, "transcript")
      _ -> %{state: :not_requested, content: nil, error: nil}
    end
  end

  defp resolve_original_file_url(item, artifacts) do
    # Find the original download artifact to get the source file
    artifact =
      Enum.find(artifacts, fn a ->
        a.labels["origin"] == "original" and
          a.labels["type"] in ["pdf", "initial_download"] and
          a.status == "produced" and
          a.filenames != []
      end) ||
        Enum.find(artifacts, fn a ->
          a.labels["origin"] == "original" and
            a.labels["format"] in ["video", "audio", "document"] and
            a.status == "produced" and
            a.filenames != []
        end)

    if artifact do
      filename = artifact.filenames |> List.first() |> Path.basename()
      ~p"/api/v1/items/#{item.id}/files/#{filename}"
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
          {:ok, content} ->
            %{state: :available, content: content, html: md_to_html(content), error: nil}

          {:error, _} ->
            %{state: :available, content: "[Could not read file]", html: nil, error: nil}
        end

      has_running_stage?(stage_history, type) ->
        %{state: :processing, content: nil, html: nil, error: nil}

      failed_stage = find_failed_stage(stage_history, type) ->
        %{state: :failed, content: nil, html: nil, error: failed_stage.error}

      true ->
        %{state: :not_requested, content: nil, html: nil, error: nil}
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

  defp build_metadata_json(item) do
    base =
      %{
        "url" => item.url,
        "title" => item.title,
        "content_type" => item.content_type,
        "status" => item.status,
        "tags" => item.tags,
        "created_at" => item.inserted_at && DateTime.to_iso8601(item.inserted_at)
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    Map.merge(base, item.metadata || %{})
    |> Jason.encode!(pretty: true)
  end

  defp md_to_html(nil), do: nil

  defp md_to_html(markdown) do
    case Earmark.as_html(markdown) do
      {:ok, html, _} -> html
      _ -> nil
    end
  end

  defp format_duration(nil), do: "-"

  defp format_duration(ms) when ms < 1000, do: "#{ms}ms"

  defp format_duration(ms) do
    seconds = div(ms, 1000)
    remaining_ms = rem(ms, 1000)

    if seconds < 60 do
      "#{seconds}.#{div(remaining_ms, 100)}s"
    else
      minutes = div(seconds, 60)
      remaining_seconds = rem(seconds, 60)
      "#{minutes}m #{remaining_seconds}s"
    end
  end

  defp is_processing?(item), do: item.status in ["bootstrapping", "processing"]

  defp has_failed_stages?(stage_history) do
    Enum.any?(stage_history, &(&1.status == "failed"))
  end

  defp unique_stages(stage_history) do
    stage_history
    |> Enum.map(& &1.stage)
    |> Enum.uniq()
  end

  defp tabs_for(item) do
    base =
      case item.content_type do
        type when type in ["video", "podcast"] ->
          ["summary", "transcript"]

        _ ->
          ["summary"]
      end

    base ++ ["pipeline", "metadata", "chat", "actions"]
  end

  defp tab_label("summary"), do: "Summary"
  defp tab_label("transcript"), do: "Transcript"
  defp tab_label("pipeline"), do: "Pipeline"
  defp tab_label("metadata"), do: "Metadata"
  defp tab_label("chat"), do: "Chat"
  defp tab_label("actions"), do: "Actions"
  defp tab_label(other), do: String.capitalize(other)
end
