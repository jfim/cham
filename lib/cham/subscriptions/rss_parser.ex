defmodule Cham.Subscriptions.RssParser do
  @moduledoc """
  Pure-function RSS 2.0 and Atom 1.0 parser using :xmerl. Returns
  entries sorted most-recent-first by timestamp (nil timestamps last).
  """

  require Record
  Record.defrecord(:xmlElement, Record.extract(:xmlElement, from_lib: "xmerl/include/xmerl.hrl"))
  Record.defrecord(:xmlText, Record.extract(:xmlText, from_lib: "xmerl/include/xmerl.hrl"))
  Record.defrecord(:xmlAttribute, Record.extract(:xmlAttribute, from_lib: "xmerl/include/xmerl.hrl"))

  @spec parse(binary()) ::
          {:ok, %{title: String.t(), description: String.t() | nil, entries: [map()]}}
          | {:error, term()}
  def parse(xml) when is_binary(xml) do
    try do
      {doc, _rest} = :xmerl_scan.string(:binary.bin_to_list(xml), quiet: true)
      parse_doc(doc)
    rescue
      e -> {:error, e}
    catch
      :exit, reason -> {:error, reason}
    end
  end

  defp parse_doc(xmlElement(name: :rss) = el), do: parse_rss(el)
  defp parse_doc(xmlElement(name: :feed) = el), do: parse_atom(el)
  defp parse_doc(_), do: {:error, :unknown_format}

  defp parse_rss(rss) do
    channel = first_child(rss, :channel)

    if is_nil(channel) do
      {:error, :no_channel}
    else
      entries =
        children(channel, :item)
        |> Enum.map(&parse_rss_item/1)
        |> sort_entries()

      {:ok,
       %{
         title: text_child(channel, :title),
         description: text_child(channel, :description),
         entries: entries
       }}
    end
  end

  defp parse_atom(feed) do
    entries =
      children(feed, :entry)
      |> Enum.map(&parse_atom_entry/1)
      |> sort_entries()

    {:ok,
     %{
       title: text_child(feed, :title),
       description: text_child(feed, :subtitle),
       entries: entries
     }}
  end

  defp parse_rss_item(item) do
    link = text_child(item, :link)
    guid = text_child(item, :guid)

    %{
      source_item_id: guid || link,
      url: link,
      title: text_child(item, :title) || link,
      timestamp: parse_rss_date(text_child(item, :pubDate))
    }
  end

  defp parse_atom_entry(entry) do
    link = atom_link(entry)
    id = text_child(entry, :id)

    %{
      source_item_id: id || link,
      url: link,
      title: text_child(entry, :title) || link,
      timestamp: parse_iso8601(text_child(entry, :updated) || text_child(entry, :published))
    }
  end

  defp sort_entries(entries) do
    Enum.sort_by(entries, fn e -> e.timestamp end, fn
      nil, _ -> false
      _, nil -> true
      a, b -> DateTime.compare(a, b) == :gt
    end)
  end

  defp children(xmlElement(content: content), name) do
    for child <- content, match?(xmlElement(name: ^name), child), do: child
  end

  defp first_child(el, name) do
    case children(el, name) do
      [c | _] -> c
      [] -> nil
    end
  end

  defp text_child(el, name) do
    case first_child(el, name) do
      nil -> nil
      child -> element_text(child)
    end
  end

  defp element_text(xmlElement(content: content)) do
    content
    |> Enum.map(fn
      xmlText(value: v) -> List.to_string(v)
      _ -> ""
    end)
    |> Enum.join("")
    |> String.trim()
    |> case do
      "" -> nil
      s -> s
    end
  end

  defp atom_link(entry) do
    case children(entry, :link) do
      [link | _] ->
        attrs = xmlElement(link, :attributes)

        Enum.find_value(attrs, fn
          xmlAttribute(name: :href, value: v) -> List.to_string(v)
          _ -> nil
        end)

      [] ->
        nil
    end
  end

  defp parse_rss_date(nil), do: nil

  defp parse_rss_date(str) do
    parse_rss_date_fallback(str)
  end

  defp parse_rss_date_fallback(str) do
    with [_dow, day, mon, year, time, tz] <- String.split(str, [" ", ", "], trim: true),
         {d, ""} <- Integer.parse(day),
         {y, ""} <- Integer.parse(year),
         m when is_integer(m) <- month_num(mon),
         [hh, mm, ss] <- String.split(time, ":"),
         {h, ""} <- Integer.parse(hh),
         {mi, ""} <- Integer.parse(mm),
         {s, ""} <- Integer.parse(ss),
         {:ok, naive} <- NaiveDateTime.new(y, m, d, h, mi, s),
         {:ok, dt} <- DateTime.from_naive(naive, "Etc/UTC") do
      apply_tz_offset(dt, tz)
    else
      _ -> nil
    end
  end

  defp apply_tz_offset(dt, "+0000"), do: dt
  defp apply_tz_offset(dt, "GMT"), do: dt
  defp apply_tz_offset(dt, "UTC"), do: dt

  defp apply_tz_offset(dt, <<sign, hh::binary-size(2), mm::binary-size(2)>>)
       when sign in [?+, ?-] do
    offset = (String.to_integer(hh) * 60 + String.to_integer(mm)) * 60
    offset = if sign == ?-, do: -offset, else: offset
    DateTime.add(dt, -offset, :second)
  end

  defp apply_tz_offset(dt, _), do: dt

  defp month_num(<<a, b, c>>) do
    month_num_lower(<<a + case a do c when c >= ?A and c <= ?Z -> 32; _ -> 0 end,
                      b + case b do c when c >= ?A and c <= ?Z -> 32; _ -> 0 end,
                      c + case c do c when c >= ?A and c <= ?Z -> 32; _ -> 0 end>>)
  end

  defp month_num(_), do: nil

  defp month_num_lower("jan"), do: 1
  defp month_num_lower("feb"), do: 2
  defp month_num_lower("mar"), do: 3
  defp month_num_lower("apr"), do: 4
  defp month_num_lower("may"), do: 5
  defp month_num_lower("jun"), do: 6
  defp month_num_lower("jul"), do: 7
  defp month_num_lower("aug"), do: 8
  defp month_num_lower("sep"), do: 9
  defp month_num_lower("oct"), do: 10
  defp month_num_lower("nov"), do: 11
  defp month_num_lower("dec"), do: 12
  defp month_num_lower(_), do: nil

  defp parse_iso8601(nil), do: nil

  defp parse_iso8601(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end
end
