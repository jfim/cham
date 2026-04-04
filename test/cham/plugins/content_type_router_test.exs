defmodule Cham.Plugins.ContentTypeRouterTest do
  use ExUnit.Case, async: true

  alias Cham.Plugins.ContentTypeRouter
  alias Cham.Plugins.ContentTypeRouter.RouteStage

  describe "Plugin behaviour" do
    test "plugin_id" do
      assert ContentTypeRouter.plugin_id() == "content_type_router"
    end

    test "name" do
      assert ContentTypeRouter.name() == "Content Type Router"
    end

    test "config_schema is empty" do
      assert ContentTypeRouter.config_schema() == []
    end

    test "init returns ok" do
      assert {:ok, %{}} = ContentTypeRouter.init(%{})
    end

    test "stages returns RouteStage" do
      assert ContentTypeRouter.stages(%{}) == [RouteStage]
    end
  end

  describe "Stage metadata" do
    test "name" do
      assert RouteStage.name() == "Content Type Router"
    end

    test "queue" do
      assert RouteStage.queue() == :general
    end

    test "max_attempts" do
      assert RouteStage.max_attempts() == 3
    end

    test "input_matchers" do
      assert RouteStage.input_matchers() == [
               %{"origin" => "original", "type" => "initial_download"}
             ]
    end

    test "output_labels" do
      assert RouteStage.output_labels() == [%{"origin" => "original", "format" => "routed"}]
    end
  end

  describe "can_process?/1" do
    test "returns ready when initial_download artifact exists" do
      artifacts = [%{"origin" => "original", "type" => "initial_download"}]

      assert {:ready, [%{"origin" => "original", "type" => "initial_download"}], []} =
               RouteStage.can_process?(artifacts)
    end

    test "returns not_applicable when no initial_download artifact" do
      artifacts = [%{"origin" => "original", "type" => "something_else"}]
      assert :not_applicable = RouteStage.can_process?(artifacts)
    end

    test "returns not_applicable for empty artifacts" do
      assert :not_applicable = RouteStage.can_process?([])
    end
  end

  describe "perform/4 routing" do
    setup do
      source_dir =
        Path.join(System.tmp_dir!(), "cham_router_src_#{:erlang.unique_integer([:positive])}")

      working_dir =
        Path.join(System.tmp_dir!(), "cham_router_dst_#{:erlang.unique_integer([:positive])}")

      File.mkdir_p!(source_dir)
      File.mkdir_p!(working_dir)

      on_exit(fn ->
        File.rm_rf!(source_dir)
        File.rm_rf!(working_dir)
      end)

      {:ok, source_dir: source_dir, working_dir: working_dir}
    end

    defp make_input(source_dir, filename, content, content_type) do
      File.write!(Path.join(source_dir, filename), content)

      [
        %{
          labels: %{
            "origin" => "original",
            "type" => "initial_download",
            "content_type" => content_type
          },
          filenames: [filename],
          input_path: source_dir
        }
      ]
    end

    test "routes text/html to article", %{source_dir: source_dir, working_dir: working_dir} do
      inputs =
        make_input(source_dir, "original.html", "<html><body>Hello</body></html>", "text/html")

      assert {:ok, result} = RouteStage.perform(inputs, working_dir, [], "item-1")

      assert [artifact] = result.artifacts
      assert artifact.labels == %{"origin" => "original", "format" => "text", "type" => "article"}
      assert artifact.filenames == ["original.html"]
      assert result.item_metadata["content_type"] == "article"

      assert File.exists?(Path.join(working_dir, "original.html"))
    end

    test "routes application/pdf to document", %{source_dir: source_dir, working_dir: working_dir} do
      inputs = make_input(source_dir, "original.pdf", "%PDF-1.4 fake pdf", "application/pdf")

      assert {:ok, result} = RouteStage.perform(inputs, working_dir, [], "item-1")

      assert [artifact] = result.artifacts
      assert artifact.labels == %{"origin" => "original", "format" => "document", "type" => "pdf"}
      assert result.item_metadata["content_type"] == "document"

      assert File.exists?(Path.join(working_dir, "original.pdf"))
    end

    test "routes video/mp4 to video", %{source_dir: source_dir, working_dir: working_dir} do
      inputs = make_input(source_dir, "original.mp4", "fake video content", "video/mp4")

      assert {:ok, result} = RouteStage.perform(inputs, working_dir, [], "item-1")

      assert [artifact] = result.artifacts
      assert artifact.labels == %{"origin" => "original", "format" => "video"}
      assert result.item_metadata["content_type"] == "video"
    end

    test "routes audio/mpeg to audio", %{source_dir: source_dir, working_dir: working_dir} do
      inputs = make_input(source_dir, "original.mp3", "fake audio content", "audio/mpeg")

      assert {:ok, result} = RouteStage.perform(inputs, working_dir, [], "item-1")

      assert [artifact] = result.artifacts
      assert artifact.labels == %{"origin" => "original", "format" => "audio"}
      assert result.item_metadata["content_type"] == "audio"
    end

    test "routes application/octet-stream to unknown when unrecognized",
         %{source_dir: source_dir, working_dir: working_dir} do
      inputs =
        make_input(source_dir, "original.bin", "random binary data", "application/octet-stream")

      assert {:ok, result} = RouteStage.perform(inputs, working_dir, [], "item-1")

      assert [artifact] = result.artifacts
      assert artifact.labels == %{"origin" => "original", "format" => "unknown"}
      assert result.item_metadata["content_type"] == "unknown"
    end

    test "magic byte detection for PDF when content type is octet-stream",
         %{source_dir: source_dir, working_dir: working_dir} do
      # Real PDF magic bytes
      pdf_content = <<0x25, 0x50, 0x44, 0x46, "-1.4 fake pdf">>
      inputs = make_input(source_dir, "original.bin", pdf_content, "application/octet-stream")

      assert {:ok, result} = RouteStage.perform(inputs, working_dir, [], "item-1")

      assert [artifact] = result.artifacts
      assert artifact.labels == %{"origin" => "original", "format" => "document", "type" => "pdf"}
      assert result.item_metadata["content_type"] == "document"
    end

    test "magic byte detection for HTML when content type is octet-stream",
         %{source_dir: source_dir, working_dir: working_dir} do
      inputs =
        make_input(
          source_dir,
          "original.bin",
          "<!DOCTYPE html><html></html>",
          "application/octet-stream"
        )

      assert {:ok, result} = RouteStage.perform(inputs, working_dir, [], "item-1")

      assert [artifact] = result.artifacts
      assert artifact.labels == %{"origin" => "original", "format" => "text", "type" => "article"}
      assert result.item_metadata["content_type"] == "article"
    end

    test "routes unknown content type to unknown", %{
      source_dir: source_dir,
      working_dir: working_dir
    } do
      inputs = make_input(source_dir, "original.xyz", "something", "application/x-custom-type")

      assert {:ok, result} = RouteStage.perform(inputs, working_dir, [], "item-1")

      assert [artifact] = result.artifacts
      assert artifact.labels == %{"origin" => "original", "format" => "unknown"}
      assert result.item_metadata["content_type"] == "unknown"
    end

    test "file is accessible in working_dir after perform",
         %{source_dir: source_dir, working_dir: working_dir} do
      content = "Hello, World!"
      inputs = make_input(source_dir, "original.html", content, "text/html")

      assert {:ok, _result} = RouteStage.perform(inputs, working_dir, [], "item-1")

      dest = Path.join(working_dir, "original.html")
      assert File.exists?(dest)
      assert File.read!(dest) == content
    end
  end
end
