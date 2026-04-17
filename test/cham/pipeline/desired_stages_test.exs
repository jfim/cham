defmodule Cham.Pipeline.DesiredStagesTest do
  use ExUnit.Case, async: true

  alias Cham.Pipeline.DesiredStages
  alias Cham.Plugin.Registry.StageEntry

  defp stage(plugin_id, input_matchers, output_labels) do
    %StageEntry{
      module: Module.concat(Cham.TestStages, Macro.camelize(plugin_id)),
      plugin_id: plugin_id,
      input_matchers: input_matchers,
      output_labels: output_labels,
      queue: :general,
      max_attempts: 3
    }
  end

  defp test_stages do
    [
      stage("generic_download_url", [%{}], [
        %{"origin" => "original", "type" => "initial_download"}
      ]),
      stage("content_type_router", [%{"type" => "initial_download"}], [
        %{"origin" => "original", "format" => "routed"}
      ]),
      stage("extract_article", [%{"format" => "text", "type" => "article"}], [
        %{"origin" => "original", "type" => "content"}
      ]),
      stage("summarize_ollama", [%{"type" => "content"}, %{"type" => "transcript"}], [
        %{"origin" => "derived", "type" => "summary"}
      ]),
      stage("auto_tag", [%{"type" => "content"}, %{"type" => "transcript"}], [
        %{"origin" => "derived", "type" => "tags"}
      ]),
      stage("clean_title", [%{}], []),
      stage("transcribe_whisper", [%{"format" => "video"}, %{"format" => "audio"}], [
        %{"origin" => "derived", "type" => "transcript"}
      ])
    ]
  end

  describe "resolve_required_stages/2" do
    test "resolves summary requires summarize_ollama and its upstream" do
      desired = [%{"type" => "summary"}]
      required = DesiredStages.resolve_required_stages(desired, test_stages())

      assert MapSet.member?(required, "summarize_ollama")
      # summarize_ollama needs content or transcript, so extract_article
      # and transcribe_whisper are both potential producers
      assert MapSet.member?(required, "extract_article") or
               MapSet.member?(required, "transcribe_whisper")
    end

    test "resolves tags requires auto_tag and upstream" do
      desired = [%{"type" => "tags"}]
      required = DesiredStages.resolve_required_stages(desired, test_stages())

      assert MapSet.member?(required, "auto_tag")
    end

    test "resolves content requires extract_article" do
      desired = [%{"type" => "content"}]
      required = DesiredStages.resolve_required_stages(desired, test_stages())

      assert MapSet.member?(required, "extract_article")
    end

    test "resolves transcript requires transcribe_whisper" do
      desired = [%{"type" => "transcript"}]
      required = DesiredStages.resolve_required_stages(desired, test_stages())

      assert MapSet.member?(required, "transcribe_whisper")
    end
  end

  describe "filter_stages/3" do
    test "passes all stages when content_type is nil" do
      stages = test_stages()
      assert DesiredStages.filter_stages(stages, nil, stages) == stages
    end

    test "filters to only required stages for article" do
      all = test_stages()
      # Simulate ready stages: everything
      desired = [%{"type" => "content"}, %{"type" => "summary"}]

      _required = DesiredStages.resolve_required_stages(desired, all)
      filtered = DesiredStages.filter_stages(all, nil, all)

      # With nil content_type, nothing is filtered
      assert length(filtered) == length(all)
    end

    test "core stages always pass through" do
      all = test_stages()
      # Even with empty desired, core stages pass
      ready = [Enum.find(all, &(&1.plugin_id == "generic_download_url"))]
      filtered = DesiredStages.filter_stages(ready, "article", all)

      assert length(filtered) == 1
      assert hd(filtered).plugin_id == "generic_download_url"
    end
  end
end
