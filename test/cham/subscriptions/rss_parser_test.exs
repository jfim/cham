defmodule Cham.Subscriptions.RssParserTest do
  use ExUnit.Case, async: true

  alias Cham.Subscriptions.RssParser

  defp fixture(name), do: File.read!(Path.join(["test", "support", "fixtures", "feeds", name]))

  test "parses RSS 2.0 with guids into feed + entries (most-recent-first)" do
    assert {:ok, %{title: "Example Blog", description: "An example feed", entries: entries}} =
             RssParser.parse(fixture("rss_2.xml"))

    assert [
             %{
               source_item_id: "urn:example:2",
               url: "https://example.com/p/2",
               title: "Post Two",
               timestamp: ts2
             },
             %{
               source_item_id: "urn:example:1",
               url: "https://example.com/p/1",
               title: "Post One",
               timestamp: ts1
             }
           ] = entries

    assert DateTime.compare(ts2, ts1) == :gt
  end

  test "parses Atom feed" do
    assert {:ok, %{title: "Atom Example", entries: [first | _]}} =
             RssParser.parse(fixture("atom.xml"))

    assert first.source_item_id == "tag:example.com,2026:2"
    assert first.url == "https://example.com/a/2"
  end

  test "uses link as source_item_id when guid is missing" do
    assert {:ok, %{entries: [%{source_item_id: "https://example.com/no-guid/2"} | _]}} =
             RssParser.parse(fixture("rss_no_guid.xml"))
  end

  test "empty feed returns empty entries" do
    assert {:ok, %{title: "Empty Blog", entries: []}} = RssParser.parse(fixture("empty.xml"))
  end

  test "invalid XML returns error" do
    assert {:error, _} = RssParser.parse("not xml at all")
  end

  test "parses UTF-8 content (accented chars) without xmerl byte/codepoint confusion" do
    assert {:ok, %{title: title, description: description, entries: [entry]}} =
             RssParser.parse(fixture("utf8.xml"))

    assert title == "Blog en français"
    assert description == "Accents and çedillas"
    assert entry.title == "Première publication"
  end
end
