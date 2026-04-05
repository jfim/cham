defmodule ChamWeb.FileControllerTest do
  use ChamWeb.ConnCase

  alias Cham.Items

  setup do
    # Create a temp archive directory with a test file
    archive_dir =
      Path.join(System.tmp_dir!(), "cham_file_test_#{:erlang.unique_integer([:positive])}")

    stage_dir = Path.join(archive_dir, "processing/extract_pdf-20260405T000000")
    File.mkdir_p!(stage_dir)
    File.write!(Path.join(stage_dir, "content.md"), "# Test PDF Content")

    {:ok, item} = Items.create_item(%{url: "https://example.com/test.pdf"})
    {:ok, item} = Items.update_item(item, %{archive_path: archive_dir, status: "complete"})

    {:ok, _artifact} =
      Items.create_artifact(%{
        item_id: item.id,
        stage: "extract_pdf",
        labels: %{"type" => "content"},
        filenames: ["content.md"],
        path: "processing/extract_pdf-20260405T000000",
        status: "produced"
      })

    on_exit(fn -> File.rm_rf!(archive_dir) end)

    %{item: item, archive_dir: archive_dir, stage_dir: stage_dir}
  end

  describe "GET /api/v1/items/:id/files/:filename" do
    test "serves a file with correct content type", %{conn: conn, item: item} do
      conn = get(conn, ~p"/api/v1/items/#{item.id}/files/content.md")
      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["text/markdown"]
      assert get_resp_header(conn, "accept-ranges") == ["bytes"]
      assert conn.resp_body == "# Test PDF Content"
    end

    test "supports range requests", %{conn: conn, item: item} do
      conn =
        conn
        |> put_req_header("range", "bytes=0-5")
        |> get(~p"/api/v1/items/#{item.id}/files/content.md")

      assert conn.status == 206
      assert get_resp_header(conn, "content-range") == ["bytes 0-5/18"]
      assert byte_size(conn.resp_body) == 6
    end

    test "supports suffix range", %{conn: conn, item: item} do
      conn =
        conn
        |> put_req_header("range", "bytes=-7")
        |> get(~p"/api/v1/items/#{item.id}/files/content.md")

      assert conn.status == 206
      assert conn.resp_body == "Content"
    end

    test "supports open-ended range", %{conn: conn, item: item} do
      conn =
        conn
        |> put_req_header("range", "bytes=2-")
        |> get(~p"/api/v1/items/#{item.id}/files/content.md")

      assert conn.status == 206
      assert conn.resp_body == "Test PDF Content"
    end

    test "returns 416 for unsatisfiable range", %{conn: conn, item: item} do
      conn =
        conn
        |> put_req_header("range", "bytes=100-200")
        |> get(~p"/api/v1/items/#{item.id}/files/content.md")

      assert conn.status == 416
    end

    test "rejects path traversal", %{conn: conn, item: item} do
      conn = get(conn, ~p"/api/v1/items/#{item.id}/files/../../etc/passwd")
      assert conn.status == 400
    end

    test "returns 404 for nonexistent file", %{conn: conn, item: item} do
      conn = get(conn, ~p"/api/v1/items/#{item.id}/files/nonexistent.txt")
      assert conn.status == 404
    end

    test "returns 404 for nonexistent item", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/items/00000000-0000-0000-0000-000000000000/files/test.md")
      assert conn.status == 404
    end
  end
end
