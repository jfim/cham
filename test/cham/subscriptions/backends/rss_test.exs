defmodule Cham.Subscriptions.Backends.RSSTest do
  use ExUnit.Case, async: true

  alias Cham.Subscriptions.Backends.RSS

  defp fixture(name), do: File.read!(Path.join(["test", "support", "fixtures", "feeds", name]))

  setup do
    bypass = Bypass.open()
    {:ok, bypass: bypass, base_url: "http://localhost:#{bypass.port}"}
  end

  test "id/name", _ do
    assert RSS.id() == :cham_rss
    assert RSS.name() == "RSS/Atom"
  end

  test "stream_pages returns one page of entries", %{bypass: bypass, base_url: base} do
    Bypass.expect_once(bypass, "GET", "/feed.xml", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/rss+xml")
      |> Plug.Conn.resp(200, fixture("rss_2.xml"))
    end)

    pages = RSS.stream_pages("#{base}/feed.xml") |> Enum.to_list()

    assert length(pages) == 1
    [page] = pages
    assert length(page) == 2
    assert hd(page).source_item_id == "urn:example:2"
  end

  test "stream_pages raises on HTTP error", %{bypass: bypass, base_url: base} do
    Bypass.expect_once(bypass, "GET", "/dead.xml", fn conn ->
      Plug.Conn.resp(conn, 404, "not found")
    end)

    assert_raise RuntimeError, fn ->
      RSS.stream_pages("#{base}/dead.xml") |> Enum.to_list()
    end
  end
end
