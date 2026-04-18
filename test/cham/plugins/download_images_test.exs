defmodule Cham.Plugins.DownloadImagesTest do
  use ExUnit.Case, async: true

  alias Cham.Plugins.DownloadImages
  alias Cham.Plugins.DownloadImages.Stage

  describe "Plugin behaviour" do
    test "plugin_id" do
      assert DownloadImages.plugin_id() == "download_images"
    end

    test "stages returns Stage" do
      assert DownloadImages.stages(%{}) == [Stage]
    end

    test "config_schema is empty" do
      assert DownloadImages.config_schema() == []
    end
  end

  describe "Stage metadata" do
    test "queue" do
      assert Stage.queue() == :general
    end

    test "input_matchers" do
      assert Stage.input_matchers() == [
               %{
                 "origin" => "original",
                 "format" => "text",
                 "type" => "content",
                 "content_type" => "text/markdown"
               }
             ]
    end

    test "output_labels" do
      assert Stage.output_labels() == [
               %{
                 "origin" => "derived",
                 "format" => "text",
                 "type" => "content",
                 "content_type" => "text/markdown",
                 "provider" => "download_images"
               }
             ]
    end
  end

  describe "can_process?/1" do
    test "ready when a markdown content artifact exists" do
      artifacts = [
        %{
          "origin" => "original",
          "format" => "text",
          "type" => "content",
          "content_type" => "text/markdown"
        }
      ]

      assert {:ready, _, []} = Stage.can_process?(artifacts)
    end

    test "not_applicable without markdown content" do
      artifacts = [%{"origin" => "original", "format" => "text", "type" => "article"}]
      assert :not_applicable = Stage.can_process?(artifacts)
    end

    test "not_applicable for empty artifacts" do
      assert :not_applicable = Stage.can_process?([])
    end
  end
end
