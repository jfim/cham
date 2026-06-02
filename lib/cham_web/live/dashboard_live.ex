defmodule ChamWeb.DashboardLive do
  use ChamWeb, :live_view

  alias Cham.Items
  alias Cham.Pipeline
  alias ChamWeb.DashboardLive.DetailHelpers

  @page_size 50

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Cham.EventBus.subscribe("item")
      Cham.EventBus.subscribe("pipeline")
    end

    socket =
      socket
      |> assign(:page_title, "Dashboard")
      |> assign(:show_in_progress, false)
      |> assign(:show_tags, false)
      |> assign(:show_submit_modal, false)
      |> assign(:submit_error, nil)
      |> assign(:page_size, @page_size)
      |> assign(:view, :list)
      |> assign(:selected_item_id, nil)
      |> assign(:selected_item_title, nil)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case socket.assigns.live_action do
      :detail -> apply_detail(socket, params)
      _ -> apply_list(socket, params)
    end
  end

  defp apply_detail(socket, %{"id" => id} = params) do
    item = Items.get_item!(id)
    return_path = DetailHelpers.build_return_path(params)

    socket =
      socket
      |> assign(:view, :detail)
      |> assign(:selected_item_id, id)
      |> assign(:page_title, item.title || "Item Detail")
      |> assign(:return_path, return_path)
      |> DetailHelpers.assign_detail_defaults()
      |> DetailHelpers.assign_detail(item)
      |> ensure_list_loaded()
      |> ensure_stats_loaded()

    {:noreply, socket}
  end

  defp apply_list(socket, params) do
    active_type = Map.get(params, "type")
    active_tag = Map.get(params, "tag")
    search_query = params |> Map.get("q", "") |> to_string() |> String.trim()
    page = parse_page(Map.get(params, "page"))

    filters = build_filters(active_type, active_tag, search_query)

    {items, total_count} =
      Items.list_items_paginated(filters, page: page, page_size: @page_size)

    total_pages = max(div(total_count + @page_size - 1, @page_size), 1)

    socket =
      socket
      |> assign(:view, :list)
      |> assign(:selected_item_id, nil)
      |> assign(:selected_item_title, nil)
      |> assign(:items, items)
      |> assign(:active_type, active_type)
      |> assign(:active_tag, active_tag)
      |> assign(:search_query, search_query)
      |> assign(:page, page)
      |> assign(:total_pages, total_pages)
      |> assign(:filtered_count, total_count)
      |> ensure_stats_loaded()

    {:noreply, socket}
  end

  defp ensure_list_loaded(socket) do
    if Map.has_key?(socket.assigns, :items) do
      socket
    else
      filters = build_filters(nil, nil, "")
      {items, total_count} = Items.list_items_paginated(filters, page: 1, page_size: @page_size)
      total_pages = max(div(total_count + @page_size - 1, @page_size), 1)

      socket
      |> assign(:items, items)
      |> assign(:active_type, nil)
      |> assign(:active_tag, nil)
      |> assign(:search_query, "")
      |> assign(:page, 1)
      |> assign(:total_pages, total_pages)
      |> assign(:filtered_count, total_count)
    end
  end

  defp ensure_stats_loaded(socket) do
    if Map.has_key?(socket.assigns, :total_count) do
      socket
    else
      load_stats(socket)
    end
  end

  defp load_stats(socket) do
    in_progress = Items.list_in_progress_items()

    active_count =
      Enum.count(in_progress, &(&1.status in ["bootstrapping", "processing"]))

    %{type_counts: type_counts, tag_counts: tag_counts, total_count: total_count} =
      Cham.Items.StatsCache.stats()

    socket
    |> assign(:in_progress, in_progress)
    |> assign(:active_count, active_count)
    |> assign(:type_counts, type_counts)
    |> assign(:tag_counts, tag_counts)
    |> assign(:total_count, total_count)
  end

  @impl true
  def handle_event("toggle_in_progress", _params, socket) do
    {:noreply, assign(socket, :show_in_progress, !socket.assigns.show_in_progress)}
  end

  def handle_event("toggle_tags", _params, socket) do
    {:noreply, assign(socket, :show_tags, !socket.assigns.show_tags)}
  end

  def handle_event("filter_type", %{"type" => type}, socket) do
    new_type = if type == socket.assigns.active_type, do: nil, else: type

    params =
      current_query_params(socket, type: new_type, page: nil)

    {:noreply, push_patch(socket, to: ~p"/?#{params}")}
  end

  def handle_event("filter_tag", %{"tag" => tag}, socket) do
    new_tag = if tag == socket.assigns.active_tag, do: nil, else: tag

    params =
      current_query_params(socket, tag: new_tag, page: nil)

    {:noreply, push_patch(socket, to: ~p"/?#{params}")}
  end

  def handle_event("search", %{"q" => q}, socket) do
    trimmed = String.trim(q)
    params = current_query_params(socket, q: nullify_empty(trimmed), page: nil)
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

  # ---------- Detail-view event handlers ----------

  def handle_event("select_tab", %{"tab" => tab}, socket) do
    new_tab = if socket.assigns.active_tab == tab, do: nil, else: tab

    socket =
      socket
      |> assign(:active_tab, new_tab)
      |> DetailHelpers.maybe_load_transcript(new_tab)
      |> DetailHelpers.maybe_load_files(new_tab)

    {:noreply, socket}
  end

  def handle_event("retry_failed", _params, socket) do
    case Pipeline.reprocess(socket.assigns.item.id, retry_failed: true) do
      {:ok, _} -> {:noreply, put_flash(socket, :info, "Retrying failed stages...")}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Failed to retry")}
    end
  end

  def handle_event("invalidate_stage", %{"stage" => stage_id}, socket) do
    case Pipeline.reprocess(socket.assigns.item.id, invalidate: [stage_id]) do
      {:ok, _} -> {:noreply, put_flash(socket, :info, "Rerunning #{stage_id}...")}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Failed to reprocess stage")}
    end
  end

  def handle_event("subscribe", params, socket) do
    backfill = DetailHelpers.parse_backfill_params(params["backfill"] || %{})

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
      Pipeline.cancel(item.id)
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

    case Pipeline.reprocess(item.id, invalidate: stage_ids) do
      {:ok, _} -> {:noreply, put_flash(socket, :info, "Reprocessing all stages...")}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Failed to reprocess")}
    end
  end

  @impl true
  def handle_info(event, socket) do
    filters =
      build_filters(
        socket.assigns.active_type,
        socket.assigns.active_tag,
        socket.assigns[:search_query] || ""
      )

    {items, total_count} =
      Items.list_items_paginated(filters,
        page: socket.assigns[:page] || 1,
        page_size: @page_size
      )

    total_pages = max(div(total_count + @page_size - 1, @page_size), 1)

    socket =
      socket
      |> assign(:items, items)
      |> assign(:filtered_count, total_count)
      |> assign(:total_pages, total_pages)
      |> load_stats()
      |> maybe_refresh_detail(event)

    {:noreply, socket}
  end

  defp maybe_refresh_detail(socket, event) do
    case socket.assigns do
      %{view: :detail, item: %{id: item_id}} ->
        if DetailHelpers.event_for_item?(event, item_id) do
          item = Items.get_item!(item_id)

          socket
          |> assign(:page_title, item.title || "Item Detail")
          |> DetailHelpers.assign_detail(item)
        else
          socket
        end

      _ ->
        socket
    end
  end

  defp build_filters(active_type, active_tag, search_query) do
    []
    |> then(fn f -> if active_type, do: [{:content_type, active_type} | f], else: f end)
    |> then(fn f -> if active_tag, do: [{:tag, active_tag} | f], else: f end)
    |> then(fn f ->
      if is_binary(search_query) and search_query != "",
        do: [{:search, search_query} | f],
        else: f
    end)
  end

  defp parse_page(nil), do: 1
  defp parse_page(""), do: 1

  defp parse_page(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} when n >= 1 -> n
      _ -> 1
    end
  end

  defp parse_page(_), do: 1

  defp nullify_empty(""), do: nil
  defp nullify_empty(value), do: value

  # Builds the query-params map preserving current filters, with overrides.
  # `nil` override removes that key. `page` is dropped unless explicitly set.
  defp current_query_params(socket, overrides) do
    base = %{
      "type" => socket.assigns.active_type,
      "tag" => socket.assigns.active_tag,
      "q" => nullify_empty(socket.assigns[:search_query] || ""),
      "page" => nil
    }

    overrides
    |> Enum.reduce(base, fn {k, v}, acc -> Map.put(acc, to_string(k), v) end)
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
    |> Map.new()
  end

  defp hero_text(assigns) do
    n = fn count -> "<strong>#{count}</strong>" end

    q = fn s ->
      "&ldquo;#{Phoenix.HTML.html_escape(s) |> Phoenix.HTML.safe_to_string()}&rdquo;"
    end

    cond do
      assigns.search_query && assigns.search_query != "" ->
        "Cham found #{n.(assigns.filtered_count)} #{pluralize("result", assigns.filtered_count)} for #{q.(assigns.search_query)}"

      assigns.active_type && assigns.active_tag ->
        "Cham knows about #{n.(assigns.filtered_count)} #{content_type_noun(assigns.active_type, assigns.filtered_count)} tagged #{q.(assigns.active_tag)}"

      assigns.active_type ->
        "Cham knows about #{n.(assigns.filtered_count)} #{content_type_noun(assigns.active_type, assigns.filtered_count)}"

      assigns.active_tag ->
        "Cham knows about #{n.(assigns.filtered_count)} #{pluralize("item", assigns.filtered_count)} tagged #{q.(assigns.active_tag)}"

      assigns.total_count == 0 ->
        "Cham is empty"

      true ->
        "Cham knows about #{n.(assigns.total_count)} pieces of information"
    end
  end

  defp pluralize(word, 1), do: word
  defp pluralize(word, _), do: word <> "s"

  defp truncate_url(nil), do: ""

  defp truncate_url(url) do
    case URI.parse(url) do
      %URI{host: host, path: path} when is_binary(host) ->
        display = host <> (path || "")

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

  defp page_params(assigns, page) do
    %{}
    |> then(fn p ->
      if assigns.active_type, do: Map.put(p, "type", assigns.active_type), else: p
    end)
    |> then(fn p -> if assigns.active_tag, do: Map.put(p, "tag", assigns.active_tag), else: p end)
    |> then(fn p ->
      if assigns.search_query && assigns.search_query != "",
        do: Map.put(p, "q", assigns.search_query),
        else: p
    end)
    |> then(fn p -> if page > 1, do: Map.put(p, "page", Integer.to_string(page)), else: p end)
  end

  defp video_meta_line(%Cham.Items.Item{} = item) do
    host =
      case URI.parse(item.url || "") do
        %URI{host: h} when is_binary(h) and h != "" -> h
        _ -> nil
      end

    duration =
      case item.metadata && item.metadata["duration_seconds"] do
        s when is_integer(s) and s > 0 -> format_duration(s)
        s when is_float(s) and s > 0 -> format_duration(round(s))
        _ -> nil
      end

    uploader =
      case item.metadata && item.metadata["uploader"] do
        u when is_binary(u) and u != "" -> u
        _ -> nil
      end

    [duration, uploader, host]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> item.url || ""
      parts -> Enum.join(parts, " · ")
    end
  end

  defp format_duration(seconds) when seconds >= 3600 do
    h = div(seconds, 3600)
    m = div(rem(seconds, 3600), 60)
    s = rem(seconds, 60)
    "#{h}:#{pad2(m)}:#{pad2(s)}"
  end

  defp format_duration(seconds) do
    m = div(seconds, 60)
    s = rem(seconds, 60)
    "#{m}:#{pad2(s)}"
  end

  defp pad2(n) when n < 10, do: "0#{n}"
  defp pad2(n), do: Integer.to_string(n)

  defp meta_line(%Cham.Items.Item{} = item) do
    host =
      case URI.parse(item.url || "") do
        %URI{host: h} when is_binary(h) and h != "" -> h
        _ -> nil
      end

    wc = item.metadata && item.metadata["word_count"]

    duration =
      case item.metadata && (item.metadata["duration_seconds"] || item.metadata["duration"]) do
        s when is_integer(s) and s > 0 -> format_duration(s)
        s when is_float(s) and s > 0 -> format_duration(round(s))
        _ -> nil
      end

    uploader =
      case item.metadata && item.metadata["uploader"] do
        u when is_binary(u) and u != "" -> u
        _ -> nil
      end

    parts =
      []
      |> then(fn p -> if duration, do: [duration | p], else: p end)
      |> then(fn p -> if uploader, do: [uploader | p], else: p end)
      |> then(fn p -> if wc && wc > 0, do: ["#{format_word_count(wc)} words" | p], else: p end)
      |> then(fn p ->
        if wc && wc > 0, do: ["#{reading_time_minutes(wc)} min read" | p], else: p
      end)
      |> then(fn p -> if host, do: [host | p], else: p end)
      |> Enum.reverse()

    case parts do
      [] -> item.url || ""
      parts -> Enum.join(parts, " · ")
    end
  end

  defp format_word_count(n) when n >= 1_000, do: "#{Float.round(n / 1000, 1)}k"
  defp format_word_count(n), do: Integer.to_string(n)

  defp reading_time_minutes(word_count) do
    # ~200 wpm is the common readability heuristic
    max(1, div(word_count + 199, 200))
  end

  defp content_type_label(type) do
    case type do
      "article" -> "Articles"
      "video" -> "Videos"
      "document" -> "Documents"
      "podcast" -> "Podcasts"
      "feed" -> "Feeds"
      _ -> String.capitalize(type || "Items") <> "s"
    end
  end

  defp content_type_noun(type, count) do
    {singular, plural} =
      case type do
        "article" -> {"article", "articles"}
        "video" -> {"video", "videos"}
        "document" -> {"document", "documents"}
        "podcast" -> {"podcast", "podcasts"}
        "feed" -> {"feed", "feeds"}
        _ -> {"item", "items"}
      end

    if count == 1, do: singular, else: plural
  end

  @doc false
  def group_items_by_day(items, today \\ Date.utc_today()) do
    items
    |> Enum.group_by(&day_bucket(&1, today))
    |> Enum.sort_by(fn {bucket, _} -> bucket_sort_key(bucket, today) end)
    |> Enum.map(fn {bucket, items} ->
      {bucket_label(bucket, today), items}
    end)
  end

  defp item_date(%{inserted_at: %DateTime{} = dt}), do: DateTime.to_date(dt)
  defp item_date(%{inserted_at: %NaiveDateTime{} = dt}), do: NaiveDateTime.to_date(dt)
  defp item_date(_), do: nil

  defp day_bucket(item, today) do
    case item_date(item) do
      nil ->
        {:older, nil}

      date ->
        days = Date.diff(today, date)

        cond do
          days <= 0 -> :today
          days == 1 -> :yesterday
          days <= 6 -> {:weekday, date}
          days <= 13 -> :last_week
          date.year == today.year and date.month == today.month -> :this_month
          true -> {:month, date.year, date.month}
        end
    end
  end

  defp bucket_sort_key(:today, _), do: 0
  defp bucket_sort_key(:yesterday, _), do: 1
  defp bucket_sort_key({:weekday, date}, today), do: 2 + Date.diff(today, date)
  defp bucket_sort_key(:last_week, _), do: 100
  defp bucket_sort_key(:this_month, _), do: 200
  defp bucket_sort_key({:month, y, m}, _), do: 1_000_000 - (y * 12 + m)
  defp bucket_sort_key({:older, _}, _), do: 9_999_999

  defp bucket_label(:today, _), do: "Today"
  defp bucket_label(:yesterday, _), do: "Yesterday"
  defp bucket_label({:weekday, date}, _), do: weekday_name(Date.day_of_week(date))
  defp bucket_label(:last_week, _), do: "Last week"
  defp bucket_label(:this_month, _), do: "Earlier this month"
  defp bucket_label({:month, y, m}, _), do: "#{month_name(m)} #{y}"
  defp bucket_label({:older, _}, _), do: "Undated"

  defp weekday_name(1), do: "Monday"
  defp weekday_name(2), do: "Tuesday"
  defp weekday_name(3), do: "Wednesday"
  defp weekday_name(4), do: "Thursday"
  defp weekday_name(5), do: "Friday"
  defp weekday_name(6), do: "Saturday"
  defp weekday_name(7), do: "Sunday"

  defp month_name(1), do: "January"
  defp month_name(2), do: "February"
  defp month_name(3), do: "March"
  defp month_name(4), do: "April"
  defp month_name(5), do: "May"
  defp month_name(6), do: "June"
  defp month_name(7), do: "July"
  defp month_name(8), do: "August"
  defp month_name(9), do: "September"
  defp month_name(10), do: "October"
  defp month_name(11), do: "November"
  defp month_name(12), do: "December"

  defp content_type_icon(type) do
    case type do
      "article" -> "hero-document-text"
      "video" -> "hero-play-circle"
      "document" -> "hero-document"
      "podcast" -> "hero-microphone"
      "feed" -> "hero-rss"
      _ -> "hero-document"
    end
  end
end
