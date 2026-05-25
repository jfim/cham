defmodule ChamWeb.MCPEndpointTest do
  use ChamWeb.ConnCase, async: false
  @moduletag :integration

  alias Cham.Items

  setup do
    # The MCP server's supervisor returns :ignore in :test (no Phoenix endpoint
    # running) so we explicitly start it here with `start: true`.
    start_supervised!({Cham.MCP.Server, transport: {:streamable_http, start: true}})

    tmp = Path.join(System.tmp_dir!(), "cham-mcp-int-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  defp seed(tmp) do
    n = System.unique_integer([:positive])

    {:ok, item} =
      Items.create_item(%{
        url: "https://example.com/int-#{n}",
        content_type: "article",
        status: "complete",
        title: "Integration",
        slug: "int-#{n}"
      })

    {:ok, item} = Items.update_item(item, %{archive_path: tmp})

    stage = Path.join(tmp, "content")
    File.mkdir_p!(stage)
    File.write!(Path.join(stage, "content.md"), "INT-BODY")

    {:ok, _} =
      Items.create_artifact(%{
        item_id: item.id,
        stage: "content",
        path: "content",
        filenames: ["content.md"],
        labels: %{"type" => "content", "origin" => "derived"},
        status: "produced"
      })

    item
  end

  test "tools/call get_article_markdown returns the body", %{conn: conn, tmp: tmp} do
    item = seed(tmp)

    body = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{
        "name" => "get_article_markdown",
        "arguments" => %{"id" => item.slug}
      }
    }

    resp =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> post("/mcp", Jason.encode!(body))

    assert resp.status == 200
    text = resp.resp_body
    assert text =~ "INT-BODY"
    assert text =~ item.url
  end
end
