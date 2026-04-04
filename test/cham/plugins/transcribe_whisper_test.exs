defmodule Cham.Plugins.TranscribeWhisperTest do
  use ExUnit.Case, async: true

  alias Cham.Plugins.TranscribeWhisper
  alias Cham.Plugins.TranscribeWhisper.TranscribeStage

  describe "Plugin behaviour" do
    test "plugin_id" do
      assert TranscribeWhisper.plugin_id() == "transcribe_whisper"
    end

    test "name" do
      assert TranscribeWhisper.name() == "Whisper Transcriber"
    end

    test "config_schema has model, language, and device fields" do
      schema = TranscribeWhisper.config_schema()
      assert length(schema) == 3

      model = Enum.find(schema, &(&1.key == :model))
      assert model.type == :string
      assert model.default == "turbo"

      language = Enum.find(schema, &(&1.key == :language))
      assert language.type == :string
      assert language.default == nil

      device = Enum.find(schema, &(&1.key == :device))
      assert device.type == :string
      assert device.default == "auto"
      assert device.options == ["auto", "cpu", "cuda"]
    end

    test "init returns ok" do
      assert {:ok, %{}} = TranscribeWhisper.init(%{})
    end

    test "stages returns TranscribeStage" do
      assert TranscribeWhisper.stages(%{}) == [TranscribeStage]
    end
  end

  describe "Stage metadata" do
    test "name" do
      assert TranscribeStage.name() == "Transcribe Audio"
    end

    test "queue is gpu" do
      assert TranscribeStage.queue() == :gpu
    end

    test "max_attempts" do
      assert TranscribeStage.max_attempts() == 3
    end

    test "input_matchers includes video and audio" do
      matchers = TranscribeStage.input_matchers()
      assert length(matchers) == 2
      assert %{"origin" => "original", "format" => "video"} in matchers
      assert %{"origin" => "original", "format" => "audio"} in matchers
    end

    test "output_labels" do
      assert TranscribeStage.output_labels() == [
               %{
                 "origin" => "derived",
                 "format" => "text",
                 "type" => "transcript",
                 "content_type" => "text/markdown"
               }
             ]
    end
  end

  describe "can_process?/1" do
    test "returns ready when video artifact exists" do
      artifacts = [%{"origin" => "original", "format" => "video"}]
      assert {:ready, matchers, []} = TranscribeStage.can_process?(artifacts)
      assert length(matchers) == 2
    end

    test "returns ready when audio artifact exists" do
      artifacts = [%{"origin" => "original", "format" => "audio"}]
      assert {:ready, matchers, []} = TranscribeStage.can_process?(artifacts)
      assert length(matchers) == 2
    end

    test "returns not_applicable when no media artifact" do
      artifacts = [%{"origin" => "original", "format" => "text", "type" => "article"}]
      assert :not_applicable = TranscribeStage.can_process?(artifacts)
    end

    test "returns not_applicable for empty artifacts" do
      assert :not_applicable = TranscribeStage.can_process?([])
    end
  end
end
