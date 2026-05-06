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

    {feed_metadata, existing_subscription} = load_feed_assigns(item, artifacts)

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
     |> assign(:feed_metadata, feed_metadata)
     |> assign(:existing_subscription, existing_subscription)
     |> assign_content(item, artifacts, stage_history)}
  end

  @impl true
  def handle_event("select_tab", %{"tab" => tab}, socket) do
    new_tab = if socket.assigns.active_tab == tab, do: nil, else: tab

    socket =
      socket
      |> assign(:active_tab, new_tab)
      |> maybe_load_transcript(new_tab)

    {:noreply, socket}
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
    backfill = parse_backfill_params(params["backfill"] || %{})

    attrs = %{
      title: params["title"],
      poll_interval_seconds: String.to_integer(params["poll_interval_seconds"] || "86400"),
      backfill: backfill
    }

    case Cham.Subscriptions.subscribe_from_item(socket.assigns.item.id, attrs) do
      {:ok, sub} ->
        {:noreply, push_navigate(socket, to: ~p"/subscriptions/#{sub.id}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Subscribe failed: #{inspect(reason)}")}
    end
  end

  def handle_event("delete_item", _params, socket) do
    item = socket.assigns.item

    if item.status in ~w(bootstrapping processing) do
      Cham.Pipeline.cancel(item.id)
    end

    item = Items.get_item!(item.id)

    case Items.delete_item_with_files(item) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Item deleted")
         |> push_navigate(to: socket.assigns.return_path)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete item")}
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
      existing_subscription = Cham.Subscriptions.get_by_source_url(item.url)

      {:noreply,
       socket
       |> assign(:page_title, item.title || "Item Detail")
       |> assign(:item, item)
       |> assign(:artifacts, artifacts)
       |> assign(:stage_history, stage_history)
       |> assign(:progress, progress)
       |> assign(:existing_subscription, existing_subscription)
       |> assign_content(item, artifacts, stage_history)}
    else
      {:noreply, socket}
    end
  end

  defp maybe_load_transcript(socket, "transcript") do
    case socket.assigns.transcript do
      %{state: :not_loaded} ->
        loaded =
          resolve_artifact_content(
            socket.assigns.item,
            socket.assigns.artifacts,
            socket.assigns.stage_history,
            "transcript"
          )

        assign(socket, :transcript, loaded)

      _ ->
        socket
    end
  end

  defp maybe_load_transcript(socket, _tab), do: socket

  defp parse_backfill_params(%{"mode" => "none"}), do: :none

  defp parse_backfill_params(%{"mode" => "last_n"} = p) do
    n = String.to_integer(p["n"] || "10")
    {:last_n, n}
  end

  defp parse_backfill_params(%{"mode" => "since"} = p) do
    case DateTime.from_iso8601((p["date"] || "") <> "T00:00:00Z") do
      {:ok, dt, _} -> {:since, dt}
      _ -> :none
    end
  end

  defp parse_backfill_params(_), do: :none

  defp load_feed_assigns(%{content_type: "feed"} = item, artifacts) do
    feed_meta_artifact =
      Enum.find(artifacts, fn a ->
        labels = a.labels || %{}
        labels["origin"] == "derived" and labels["type"] == "feed_metadata"
      end)

    feed_metadata =
      case feed_meta_artifact do
        nil ->
          nil

        artifact ->
          case Items.read_artifact_content(item, artifact) do
            {:ok, content} -> Jason.decode!(content)
            _ -> nil
          end
      end

    existing_subscription = Cham.Subscriptions.get_by_source_url(item.url)

    {feed_metadata, existing_subscription}
  end

  defp load_feed_assigns(_item, _artifacts), do: {nil, nil}

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
    |> assign(:transcript, lazy_transcript_placeholder(artifacts, stage_history))
    |> assign(:original_file_url, resolve_original_file_url(item, artifacts))
    |> assign(:metadata_json, build_metadata_json(item))
  end

  # Initial transcript assign without touching the filesystem. The real
  # content (and earmark render) is loaded on demand when the user opens
  # the Transcript tab — see handle_event("select_tab", "transcript", _).
  defp lazy_transcript_placeholder(artifacts, stage_history) do
    produced =
      Enum.find(artifacts, fn a ->
        a.labels["type"] == "transcript" and a.labels["origin"] == "derived" and
          a.status == "produced"
      end)

    cond do
      produced ->
        %{state: :not_loaded, content: nil, html: nil, error: nil}

      has_running_stage?(stage_history, "transcript") ->
        %{state: :processing, content: nil, html: nil, error: nil}

      failed_stage = find_failed_stage(stage_history, "transcript") ->
        %{state: :failed, content: nil, html: nil, error: failed_stage.error}

      true ->
        %{state: :not_requested, content: nil, html: nil, error: nil}
    end
  end

  defp resolve_primary_content(item, artifacts, stage_history) do
    case item.content_type do
      "article" -> resolve_article_content(item, artifacts, stage_history)
      # Video detail uses the <video> element for primary content; the transcript
      # is lazy-loaded when the user opens the Transcript tab.
      _ -> %{state: :not_requested, content: nil, error: nil}
    end
  end

  defp resolve_article_content(item, artifacts, stage_history) do
    case resolve_artifact_content(item, artifacts, stage_history, "content", "derived") do
      %{state: :available} = result ->
        result

      _ ->
        resolve_artifact_content(item, artifacts, stage_history, "content", "original")
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

  defp video_uploader(%{content_type: type, metadata: meta})
       when type in ["video", "podcast"] and is_map(meta) do
    case Map.get(meta, "uploader") do
      u when is_binary(u) and u != "" -> u
      _ -> nil
    end
  end

  defp video_uploader(_), do: nil

  defp video_duration(%{content_type: type, metadata: meta})
       when type in ["video", "podcast"] and is_map(meta) do
    case Map.get(meta, "duration_seconds") || Map.get(meta, "duration") do
      s when is_integer(s) and s > 0 -> format_seconds(s)
      s when is_float(s) and s > 0 -> format_seconds(round(s))
      _ -> nil
    end
  end

  defp video_duration(_), do: nil

  defp format_seconds(seconds) when seconds >= 3600 do
    h = div(seconds, 3600)
    m = div(rem(seconds, 3600), 60)
    s = rem(seconds, 60)
    "#{h}:#{pad2(m)}:#{pad2(s)}"
  end

  defp format_seconds(seconds) do
    m = div(seconds, 60)
    s = rem(seconds, 60)
    "#{m}:#{pad2(s)}"
  end

  defp pad2(n) when n < 10, do: "0#{n}"
  defp pad2(n), do: Integer.to_string(n)

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
