defmodule Cham.Plugins.ExtractPdfTest do
  use ExUnit.Case, async: true

  alias Cham.Plugins.ExtractPdf
  alias Cham.Plugins.ExtractPdf.ExtractStage

  describe "Plugin behaviour" do
    test "plugin_id" do
      assert ExtractPdf.plugin_id() == "extract_pdf"
    end

    test "name" do
      assert ExtractPdf.name() == "PDF Text Extractor"
    end

    test "config_schema is empty" do
      assert ExtractPdf.config_schema() == []
    end

    test "init returns ok" do
      assert {:ok, %{}} = ExtractPdf.init(%{})
    end

    test "stages returns ExtractStage" do
      assert ExtractPdf.stages(%{}) == [ExtractStage]
    end
  end

  describe "Stage metadata" do
    test "name" do
      assert ExtractStage.name() == "Extract PDF Text"
    end

    test "queue" do
      assert ExtractStage.queue() == :general
    end

    test "max_attempts" do
      assert ExtractStage.max_attempts() == 3
    end

    test "input_matchers" do
      assert ExtractStage.input_matchers() == [
               %{"origin" => "original", "format" => "document", "type" => "pdf"}
             ]
    end

    test "output_labels" do
      assert ExtractStage.output_labels() == [
               %{
                 "origin" => "original",
                 "format" => "text",
                 "type" => "content",
                 "content_type" => "text/markdown"
               }
             ]
    end
  end

  describe "can_process?/1" do
    test "returns ready when pdf artifact exists" do
      artifacts = [%{"origin" => "original", "format" => "document", "type" => "pdf"}]

      assert {:ready, [%{"origin" => "original", "format" => "document", "type" => "pdf"}], []} =
               ExtractStage.can_process?(artifacts)
    end

    test "returns not_applicable when no pdf artifact" do
      artifacts = [%{"origin" => "original", "format" => "text", "type" => "article"}]
      assert :not_applicable = ExtractStage.can_process?(artifacts)
    end

    test "returns not_applicable for empty artifacts" do
      assert :not_applicable = ExtractStage.can_process?([])
    end
  end
end
