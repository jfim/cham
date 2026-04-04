defmodule Cham.Pipeline.DAGTest do
  use ExUnit.Case, async: true

  alias Cham.Pipeline.DAG
  alias Cham.Plugin.Registry.StageEntry

  # Helper to build stage entries for testing
  defp stage(plugin_id, input_matchers, output_labels, opts \\ []) do
    %StageEntry{
      module: Module.concat(Cham.TestStages, Macro.camelize(plugin_id)),
      plugin_id: plugin_id,
      input_matchers: input_matchers,
      output_labels: output_labels,
      queue: Keyword.get(opts, :queue, :general),
      max_attempts: Keyword.get(opts, :max_attempts, 3)
    }
  end

  describe "find_ready_stages/2" do
    test "returns stages whose inputs are all satisfied" do
      stages = [
        stage("summarize", [%{"origin" => "original", "format" => "text"}], [
          %{"origin" => "derived", "type" => "summary"}
        ]),
        stage("transcribe", [%{"origin" => "original", "format" => "audio"}], [
          %{"origin" => "derived", "type" => "transcript"}
        ])
      ]

      available_artifacts = [
        %{
          labels: %{"origin" => "original", "format" => "text"},
          filenames: ["article.html"],
          path: "processing/dl-123"
        }
      ]

      ready = DAG.find_ready_stages(stages, available_artifacts)
      assert length(ready) == 1
      assert hd(ready).plugin_id == "summarize"
    end

    test "returns empty list when no stages have satisfied inputs" do
      stages = [
        stage("summarize", [%{"origin" => "original", "format" => "text"}], [
          %{"origin" => "derived", "type" => "summary"}
        ])
      ]

      available_artifacts = [
        %{labels: %{"origin" => "original", "format" => "video"}, filenames: [], path: "p/v"}
      ]

      assert DAG.find_ready_stages(stages, available_artifacts) == []
    end

    test "returns multiple stages when multiple are ready" do
      stages = [
        stage("summarize", [%{"origin" => "original", "format" => "text"}], [
          %{"origin" => "derived", "type" => "summary"}
        ]),
        stage("tag", [%{"origin" => "original", "format" => "text"}], [
          %{"origin" => "derived", "type" => "tags"}
        ])
      ]

      available_artifacts = [
        %{
          labels: %{"origin" => "original", "format" => "text"},
          filenames: ["a.html"],
          path: "p/d"
        }
      ]

      ready = DAG.find_ready_stages(stages, available_artifacts)
      assert length(ready) == 2
    end

    test "stage with empty matchers matches any artifacts" do
      stages = [
        stage("fallback_download", [%{}], [%{"origin" => "original", "format" => "text"}])
      ]

      available_artifacts = [
        %{labels: %{"domain" => "example.com"}, filenames: [], path: "p/input"}
      ]

      ready = DAG.find_ready_stages(stages, available_artifacts)
      assert length(ready) == 1
    end
  end

  describe "exclude_already_run/2" do
    test "filters out stages that have already produced artifacts" do
      stages = [
        stage("download", [%{}], [%{"origin" => "original", "format" => "text"}]),
        stage("summarize", [%{"origin" => "original", "format" => "text"}], [
          %{"origin" => "derived", "type" => "summary"}
        ])
      ]

      completed_stage_ids = MapSet.new(["download"])

      remaining = DAG.exclude_already_run(stages, completed_stage_ids)
      assert length(remaining) == 1
      assert hd(remaining).plugin_id == "summarize"
    end
  end

  describe "find_next_stages/3" do
    test "combines ready filtering with already-run exclusion" do
      stages = [
        stage("download", [%{}], [%{"origin" => "original", "format" => "text"}]),
        stage("summarize", [%{"origin" => "original", "format" => "text"}], [
          %{"origin" => "derived", "type" => "summary"}
        ])
      ]

      available_artifacts = [
        %{labels: %{"domain" => "example.com"}, filenames: [], path: "p/input"},
        %{
          labels: %{"origin" => "original", "format" => "text"},
          filenames: ["a.html"],
          path: "p/dl"
        }
      ]

      completed = MapSet.new(["download"])

      next = DAG.find_next_stages(stages, available_artifacts, completed)
      assert length(next) == 1
      assert hd(next).plugin_id == "summarize"
    end
  end

  describe "all_originals_complete?/2" do
    test "returns true when no stages produce original artifacts" do
      stages = [
        stage("summarize", [%{"format" => "text"}], [
          %{"origin" => "derived", "type" => "summary"}
        ])
      ]

      completed = MapSet.new(["summarize"])
      assert DAG.all_originals_complete?(stages, completed)
    end

    test "returns true when all original-producing stages are completed" do
      stages = [
        stage("download", [%{}], [%{"origin" => "original", "format" => "text"}]),
        stage("summarize", [%{"format" => "text"}], [
          %{"origin" => "derived", "type" => "summary"}
        ])
      ]

      completed = MapSet.new(["download"])
      assert DAG.all_originals_complete?(stages, completed)
    end

    test "returns false when original-producing stages are pending" do
      stages = [
        stage("download", [%{}], [%{"origin" => "original", "format" => "text"}])
      ]

      completed = MapSet.new()
      refute DAG.all_originals_complete?(stages, completed)
    end
  end
end
