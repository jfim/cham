defmodule ChamWeb.DashboardLive.DetailHelpers do
  @moduledoc false

  use ChamWeb, :verified_routes

  alias Cham.Items

  def assign_detail(socket, item) do
    artifacts = Items.list_artifacts(item.id)
    stage_history = Cham.JobTracking.Tracker.get_stage_history(item.id)
    progress = Cham.JobTracking.Tracker.get_progress(item.id)

    sub =
      if item.subscription_id,
        do: Cham.Subscriptions.get_subscription!(item.subscription_id),
        else: nil

    {feed_metadata, existing_subscription} = load_feed_assigns(item, artifacts)

    socket
    |> Phoenix.Component.assign(:item, item)
    |> Phoenix.Component.assign(:subscription, sub)
    |> Phoenix.Component.assign(:artifacts, artifacts)
    |> Phoenix.Component.assign(:stage_history, stage_history)
    |> Phoenix.Component.assign(:progress, progress)
    |> Phoenix.Component.assign(:feed_metadata, feed_metadata)
    |> Phoenix.Component.assign(:existing_subscription, existing_subscription)
    |> assign_content(item, artifacts, stage_history)
  end

  def assign_chat_defaults(socket) do
    socket
    |> Phoenix.Component.assign(:active_tab, nil)
    |> Phoenix.Component.assign(:chat_loaded?, false)
    |> Phoenix.Component.assign(:chat_history, [])
    |> Phoenix.Component.assign(:chat_input, "")
    |> Phoenix.Component.assign(:chat_pending, false)
    |> Phoenix.Component.assign(:chat_error, nil)
    |> Phoenix.Component.assign(:chat_source_label, nil)
    |> Phoenix.Component.assign(:chat_task_ref, nil)
  end

  def assign_content(socket, item, artifacts, stage_history) do
    socket
    |> Phoenix.Component.assign(
      :primary_content,
      resolve_primary_content(item, artifacts, stage_history)
    )
    |> Phoenix.Component.assign(
      :summary,
      resolve_artifact_content(item, artifacts, stage_history, "summary")
    )
    |> Phoenix.Component.assign(
      :transcript,
      lazy_transcript_placeholder(artifacts, stage_history)
    )
    |> Phoenix.Component.assign(:original_file_url, resolve_original_file_url(item, artifacts))
    |> Phoenix.Component.assign(:metadata_json, build_metadata_json(item))
  end

  def maybe_load_transcript(socket, "transcript") do
    case socket.assigns.transcript do
      %{state: :not_loaded} ->
        loaded =
          resolve_artifact_content(
            socket.assigns.item,
            socket.assigns.artifacts,
            socket.assigns.stage_history,
            "transcript"
          )

        Phoenix.Component.assign(socket, :transcript, loaded)

      _ ->
        socket
    end
  end

  def maybe_load_transcript(socket, _tab), do: socket

  def maybe_load_chat(socket, "chat") do
    if socket.assigns.chat_loaded? do
      socket
    else
      item = socket.assigns.item
      artifacts = socket.assigns.artifacts
      {content, label} = Cham.Chat.resolve_content(item, artifacts)

      socket
      |> Phoenix.Component.assign(:chat_loaded?, true)
      |> Phoenix.Component.assign(:chat_history, Cham.Chat.load_history(item))
      |> Phoenix.Component.assign(:chat_source_label, if(content, do: label))
    end
  end

  def maybe_load_chat(socket, _tab), do: socket

  def parse_backfill_params(%{"mode" => "none"}), do: :none

  def parse_backfill_params(%{"mode" => "last_n"} = p) do
    n = String.to_integer(p["n"] || "10")
    {:last_n, n}
  end

  def parse_backfill_params(%{"mode" => "since"} = p) do
    case DateTime.from_iso8601((p["date"] || "") <> "T00:00:00Z") do
      {:ok, dt, _} -> {:since, dt}
      _ -> :none
    end
  end

  def parse_backfill_params(_), do: :none

  def load_feed_assigns(%{content_type: "feed"} = item, artifacts) do
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

  def load_feed_assigns(_item, _artifacts), do: {nil, nil}

  def build_return_path(params) do
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

  def lazy_transcript_placeholder(artifacts, stage_history) do
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

  def resolve_primary_content(item, artifacts, stage_history) do
    case item.content_type do
      "article" -> resolve_article_content(item, artifacts, stage_history)
      _ -> %{state: :not_requested, content: nil, error: nil}
    end
  end

  defp resolve_article_content(item, artifacts, stage_history) do
    types = content_order()
    try_content_types(item, artifacts, stage_history, types, nil)
  end

  defp try_content_types(_item, _artifacts, _stage_history, [], last_result) do
    last_result || %{state: :not_requested, content: nil, html: nil, error: nil}
  end

  defp try_content_types(item, artifacts, stage_history, [type | rest], last_result) do
    derived = resolve_artifact_content(item, artifacts, stage_history, type, "derived")

    case derived do
      %{state: :available} = result ->
        result

      _ ->
        original = resolve_artifact_content(item, artifacts, stage_history, type, "original")

        case original do
          %{state: :available} = result -> result
          _ -> try_content_types(item, artifacts, stage_history, rest, last_result || derived)
        end
    end
  end

  defp content_order do
    value =
      case Cham.Config.Manager.read_all("display") do
        {:ok, cfg} -> Map.get(cfg, :content_order)
        _ -> nil
      end

    case value do
      s when is_binary(s) and s != "" ->
        s |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

      _ ->
        ["cleaned_content", "content"]
    end
  end

  def resolve_original_file_url(item, artifacts) do
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

  def resolve_artifact_content(item, artifacts, stage_history, type, origin \\ "derived") do
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

  def has_running_stage?(stage_history, type) do
    Enum.any?(stage_history, fn s ->
      s.status == "started" && String.contains?(s.stage, type)
    end)
  end

  def find_failed_stage(stage_history, type) do
    Enum.find(stage_history, fn s ->
      s.status == "failed" && String.contains?(s.stage, type)
    end)
  end

  def event_for_item?(%{item_id: event_item_id}, item_id), do: event_item_id == item_id
  def event_for_item?(%{item: %{id: event_item_id}}, item_id), do: event_item_id == item_id
  def event_for_item?(_, _), do: false

  def build_metadata_json(item) do
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

  def md_to_html(nil), do: nil

  def md_to_html(markdown) do
    case Earmark.as_html(markdown) do
      {:ok, html, _} -> html
      _ -> nil
    end
  end

  def format_duration_ms(nil), do: "-"

  def format_duration_ms(ms) when ms < 1000, do: "#{ms}ms"

  def format_duration_ms(ms) do
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

  def video_uploader(%{content_type: type, metadata: meta})
      when type in ["video", "podcast"] and is_map(meta) do
    case Map.get(meta, "uploader") do
      u when is_binary(u) and u != "" -> u
      _ -> nil
    end
  end

  def video_uploader(_), do: nil

  def video_duration(%{content_type: type, metadata: meta})
      when type in ["video", "podcast"] and is_map(meta) do
    case Map.get(meta, "duration_seconds") || Map.get(meta, "duration") do
      s when is_integer(s) and s > 0 -> format_seconds(s)
      s when is_float(s) and s > 0 -> format_seconds(round(s))
      _ -> nil
    end
  end

  def video_duration(_), do: nil

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

  def is_processing?(item), do: item.status in ["bootstrapping", "processing"]

  def has_failed_stages?(stage_history) do
    Enum.any?(stage_history, &(&1.status == "failed"))
  end

  def unique_stages(stage_history) do
    stage_history
    |> Enum.map(& &1.stage)
    |> Enum.uniq()
  end

  def tabs_for(item) do
    base =
      case item.content_type do
        type when type in ["video", "podcast"] -> ["summary", "transcript"]
        _ -> ["summary"]
      end

    base ++ ["pipeline", "metadata", "chat", "actions"]
  end

  def tab_label("summary"), do: "Summary"
  def tab_label("transcript"), do: "Transcript"
  def tab_label("pipeline"), do: "Pipeline"
  def tab_label("metadata"), do: "Metadata"
  def tab_label("chat"), do: "Chat"
  def tab_label("actions"), do: "Actions"
  def tab_label(other), do: String.capitalize(other)
end
