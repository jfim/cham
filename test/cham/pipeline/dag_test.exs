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

  describe "all_originals_complete?/3" do
    test "returns true when no stages produce original artifacts" do
      stages = [
        stage("summarize", [%{"format" => "text"}], [
          %{"origin" => "derived", "type" => "summary"}
        ])
      ]

      artifacts = [%{labels: %{"format" => "text"}}]
      completed = MapSet.new(["summarize"])
      assert DAG.all_originals_complete?(stages, artifacts, completed)
    end

    test "returns true when all original-producing stages are completed" do
      stages = [
        stage("download", [%{}], [%{"origin" => "original", "format" => "text"}]),
        stage("summarize", [%{"format" => "text"}], [
          %{"origin" => "derived", "type" => "summary"}
        ])
      ]

      artifacts = [%{labels: %{"format" => "text"}}]
      completed = MapSet.new(["download"])
      assert DAG.all_originals_complete?(stages, artifacts, completed)
    end

    test "returns false when reachable original-producing stages are pending" do
      stages = [
        stage("download", [%{}], [%{"origin" => "original", "format" => "text"}])
      ]

      artifacts = [%{labels: %{"domain" => "example.com"}}]
      completed = MapSet.new()
      # download matches any input (wildcard), so it's reachable
      refute DAG.all_originals_complete?(stages, artifacts, completed)
    end

    test "returns true when unreachable original-producing stages are pending" do
      stages = [
        stage("download", [%{}], [%{"origin" => "original", "format" => "video"}]),
        stage("extract_article", [%{"format" => "text", "type" => "article"}], [
          %{"origin" => "original", "format" => "text", "type" => "content"}
        ])
      ]

      # Only video content available — extract_article's inputs aren't satisfied
      artifacts = [%{labels: %{"format" => "video", "origin" => "original"}}]
      completed = MapSet.new(["download"])
      assert DAG.all_originals_complete?(stages, artifacts, completed)
    end
  end

  describe "find_downstream_stages/2" do
    test "finds direct downstream stages" do
      stages = [
        stage("transcribe", [%{"format" => "video"}], [
          %{"origin" => "derived", "type" => "transcript"}
        ]),
        stage("summarize", [%{"type" => "transcript"}], [
          %{"origin" => "derived", "type" => "summary"}
        ]),
        stage("unrelated", [%{"format" => "image"}], [%{"type" => "thumbnail"}])
      ]

      downstream = DAG.find_downstream_stages(stages, "transcribe")
      ids = Enum.map(downstream, & &1.plugin_id)
      assert "summarize" in ids
      refute "unrelated" in ids
    end

    test "cascades transitively" do
      stages = [
        stage("transcribe", [%{"format" => "video"}], [
          %{"origin" => "derived", "type" => "transcript"}
        ]),
        stage("summarize", [%{"type" => "transcript"}], [
          %{"origin" => "derived", "type" => "summary"}
        ]),
        stage("auto_tag", [%{"type" => "summary"}], [
          %{"origin" => "derived", "type" => "tags"}
        ])
      ]

      downstream = DAG.find_downstream_stages(stages, "transcribe")
      ids = Enum.map(downstream, & &1.plugin_id)
      assert "summarize" in ids
      assert "auto_tag" in ids
    end

    test "returns empty for unknown stage" do
      stages = [
        stage("summarize", [%{"type" => "transcript"}], [%{"type" => "summary"}])
      ]

      assert DAG.find_downstream_stages(stages, "nonexistent") == []
    end

    test "returns empty when no downstream stages exist" do
      stages = [
        stage("summarize", [%{"type" => "transcript"}], [%{"type" => "summary"}]),
        stage("transcribe", [%{"format" => "video"}], [%{"type" => "transcript"}])
      ]

      assert DAG.find_downstream_stages(stages, "summarize") == []
    end

    test "ignores stages whose only matcher is empty (match-all fallback)" do
      # Regression: download stages declared input_matchers: [%{}] as a
      # match-all sigil. find_downstream_stages then treated them as
      # downstream of every stage's outputs, cascading to mark the entire
      # pipeline as downstream — so invalidating any stage wiped the
      # download artifact too.
      stages = [
        stage("transcribe", [%{"format" => "video"}], [%{"type" => "transcript"}]),
        stage("summarize", [%{"type" => "transcript"}], [%{"type" => "summary"}]),
        stage("download_ytdlp", [%{}], [%{"type" => "initial_download"}])
      ]

      downstream = DAG.find_downstream_stages(stages, "summarize")
      assert downstream == []
    end
  end
end
