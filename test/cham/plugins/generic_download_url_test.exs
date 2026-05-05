defmodule Cham.Plugins.GenericDownloadUrlTest do
  use Cham.DataCase

  alias Cham.Plugins.GenericDownloadUrl
  alias Cham.Plugins.GenericDownloadUrl.DownloadStage

  describe "Plugin behaviour" do
    test "plugin_id" do
      assert GenericDownloadUrl.plugin_id() == "generic_download_url"
    end

    test "name" do
      assert GenericDownloadUrl.name() == "Generic URL Downloader"
    end

    test "config_schema returns timeout and max_body_size fields" do
      schema = GenericDownloadUrl.config_schema()
      assert length(schema) == 2

      timeout_field = Enum.find(schema, &(&1.key == :timeout))
      assert timeout_field.type == :integer
      assert timeout_field.default == 300_000

      max_body_field = Enum.find(schema, &(&1.key == :max_body_size))
      assert max_body_field.type == :integer
      assert max_body_field.default == 524_288_000
    end

    test "init returns ok" do
      assert {:ok, %{}} = GenericDownloadUrl.init(%{})
    end

    test "stages returns DownloadStage" do
      assert GenericDownloadUrl.stages(%{}) == [DownloadStage]
    end
  end

  describe "Stage metadata" do
    test "name" do
      assert DownloadStage.name() == "Download URL"
    end

    test "queue" do
      assert DownloadStage.queue() == :network
    end

    test "max_attempts" do
      assert DownloadStage.max_attempts() == 3
    end

    test "input_matchers is wildcard" do
      assert DownloadStage.input_matchers() == [%{}]
    end

    test "output_labels" do
      assert DownloadStage.output_labels() == [
               %{"origin" => "original", "type" => "initial_download"}
             ]
    end
  end

  describe "perform/5" do
    setup do
      bypass = Bypass.open()
      {:ok, bypass: bypass, base_url: "http://localhost:#{bypass.port}"}
    end

    test "successful download streams file to working dir", %{bypass: bypass, base_url: base_url} do
      body = "Hello, World!"

      Bypass.expect(bypass, "HEAD", "/test.html", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "text/html; charset=utf-8")
        |> Plug.Conn.put_resp_header("content-length", Integer.to_string(byte_size(body)))
        |> Plug.Conn.resp(200, "")
      end)

      Bypass.expect(bypass, "GET", "/test.html", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "text/html; charset=utf-8")
        |> Plug.Conn.resp(200, body)
      end)

      url = "#{base_url}/test.html"
      {:ok, item} = Cham.Items.create_item(%{url: url, slug: "test-download"})

      working_dir =
        Path.join(System.tmp_dir!(), "cham_test_#{:erlang.unique_integer([:positive])}")

      File.mkdir_p!(working_dir)

      on_exit(fn -> File.rm_rf!(working_dir) end)

      config = %{timeout: 30_000, max_body_size: 524_288_000}

      assert {:ok, result} = DownloadStage.perform([], working_dir, [], item.id, config)

      assert [artifact] = result.artifacts
      assert artifact.labels["origin"] == "original"
      assert artifact.labels["type"] == "initial_download"
      assert artifact.labels["content_type"] == "text/html"
      assert artifact.filenames == ["original.html"]

      assert result.item_metadata["content_type"] == "text/html"
      # Cowboy strips the body for HEAD requests and overrides content-length to 0
      # when sending an empty response body; the value is still recorded in metadata
      assert is_integer(result.item_metadata["content_length"])

      file_path = Path.join(working_dir, "original.html")
      assert File.read!(file_path) == body
    end

    test "rejects content exceeding max_body_size", %{bypass: bypass, base_url: base_url} do
      Bypass.expect(bypass, "HEAD", "/large-file.bin", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/octet-stream")
        |> Plug.Conn.put_resp_header("content-length", "0")
        |> Plug.Conn.resp(200, "")
      end)

      url = "#{base_url}/large-file.bin"
      {:ok, item} = Cham.Items.create_item(%{url: url, slug: "test-large"})

      working_dir =
        Path.join(System.tmp_dir!(), "cham_test_#{:erlang.unique_integer([:positive])}")

      File.mkdir_p!(working_dir)

      on_exit(fn -> File.rm_rf!(working_dir) end)

      # Set max_body_size to -1 so that any reported content-length (including 0) exceeds it.
      # Cowboy overrides content-length to 0 for empty HEAD response bodies.
      config = %{timeout: 30_000, max_body_size: -1}

      assert {:error, msg} = DownloadStage.perform([], working_dir, [], item.id, config)
      assert msg =~ "Content too large"
      assert msg =~ "exceeds limit"
    end

    test "handles HTTP 404 error", %{bypass: bypass, base_url: base_url} do
      Bypass.expect(bypass, "HEAD", "/not-found", fn conn ->
        Plug.Conn.resp(conn, 404, "Not Found")
      end)

      # HEAD fails with 404, so downloader falls through to GET which also returns 404
      Bypass.expect(bypass, "GET", "/not-found", fn conn ->
        Plug.Conn.resp(conn, 404, "Not Found")
      end)

      url = "#{base_url}/not-found"
      {:ok, item} = Cham.Items.create_item(%{url: url, slug: "test-404"})

      working_dir =
        Path.join(System.tmp_dir!(), "cham_test_#{:erlang.unique_integer([:positive])}")

      File.mkdir_p!(working_dir)

      on_exit(fn -> File.rm_rf!(working_dir) end)

      config = %{timeout: 30_000, max_body_size: 524_288_000}

      assert {:error, msg} = DownloadStage.perform([], working_dir, [], item.id, config)
      assert msg =~ "404"
    end

    test "uses extension from URL path when content type is octet-stream", %{
      bypass: bypass,
      base_url: base_url
    } do
      body = <<0, 1, 2, 3>>

      Bypass.expect(bypass, "HEAD", "/file.pdf", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/octet-stream")
        |> Plug.Conn.put_resp_header("content-length", Integer.to_string(byte_size(body)))
        |> Plug.Conn.resp(200, "")
      end)

      Bypass.expect(bypass, "GET", "/file.pdf", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/octet-stream")
        |> Plug.Conn.resp(200, body)
      end)

      url = "#{base_url}/file.pdf"
      {:ok, item} = Cham.Items.create_item(%{url: url, slug: "test-pdf-ext"})

      working_dir =
        Path.join(System.tmp_dir!(), "cham_test_#{:erlang.unique_integer([:positive])}")

      File.mkdir_p!(working_dir)

      on_exit(fn -> File.rm_rf!(working_dir) end)

      config = %{timeout: 30_000, max_body_size: 524_288_000}

      assert {:ok, result} = DownloadStage.perform([], working_dir, [], item.id, config)
      assert [artifact] = result.artifacts
      assert artifact.filenames == ["original.pdf"]
    end
  end
end
