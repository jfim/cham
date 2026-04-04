defmodule Cham.Archive.MetadataManagerTest do
  use ExUnit.Case, async: true

  alias Cham.Archive.MetadataManager

  setup do
    root = Path.join(System.tmp_dir!(), "cham_meta_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  defp write_artifact_json(item_dir, stage_dir_name, data) do
    dir = Path.join([item_dir, "processing", stage_dir_name])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "artifact.json"), Jason.encode!(data))
    dir
  end

  describe "read_artifact_json/1" do
    test "parses a valid artifact.json file", %{root: root} do
      dir =
        write_artifact_json(root, "input-20260402T143000Z", %{
          "stage" => %{
            "plugin_id" => "input",
            "start_ts" => 1_743_609_000,
            "end_ts" => 1_743_609_001
          },
          "artifacts" => [%{"labels" => %{"domain" => "example.com"}, "filenames" => []}],
          "item_metadata" => %{"url" => "https://example.com"}
        })

      assert {:ok, data} = MetadataManager.read_artifact_json(dir)
      assert data["stage"]["plugin_id"] == "input"
      assert length(data["artifacts"]) == 1
    end

    test "returns error for missing file", %{root: root} do
      assert {:error, :not_found} =
               MetadataManager.read_artifact_json(Path.join(root, "nonexistent"))
    end

    test "returns error for invalid JSON", %{root: root} do
      dir = Path.join([root, "processing", "bad-20260402T143000Z"])
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "artifact.json"), "not json{{{")
      assert {:error, _} = MetadataManager.read_artifact_json(dir)
    end
  end

  describe "merge_item_state/1" do
    test "merges artifacts from multiple stages with latest-timestamp-wins", %{root: root} do
      write_artifact_json(root, "input-20260402T143000Z", %{
        "stage" => %{
          "plugin_id" => "input",
          "start_ts" => 1_743_609_000,
          "end_ts" => 1_743_609_001
        },
        "artifacts" => [%{"labels" => %{"domain" => "example.com"}, "filenames" => []}],
        "item_metadata" => %{"url" => "https://example.com", "title" => "Original Title"}
      })

      write_artifact_json(root, "download-20260402T143005Z", %{
        "stage" => %{
          "plugin_id" => "download",
          "start_ts" => 1_743_609_005,
          "end_ts" => 1_743_609_060
        },
        "artifacts" => [
          %{
            "labels" => %{"origin" => "original", "format" => "text"},
            "filenames" => ["content.html"]
          }
        ],
        "item_metadata" => %{"title" => "Downloaded Title", "content_type" => "article"}
      })

      assert {:ok, state} = MetadataManager.merge_item_state(root)
      assert length(state.artifacts) == 2
      assert state.metadata["title"] == "Downloaded Title"
      assert state.metadata["url"] == "https://example.com"
      assert state.metadata["content_type"] == "article"
    end

    test "returns empty state for item with no processing dirs", %{root: root} do
      assert {:ok, state} = MetadataManager.merge_item_state(root)
      assert state.artifacts == []
      assert state.metadata == %{}
    end
  end

  describe "get_latest/2" do
    test "returns most recent metadata value", %{root: root} do
      write_artifact_json(root, "input-20260402T143000Z", %{
        "stage" => %{
          "plugin_id" => "input",
          "start_ts" => 1_743_609_000,
          "end_ts" => 1_743_609_001
        },
        "artifacts" => [],
        "item_metadata" => %{"title" => "First"}
      })

      write_artifact_json(root, "clean_title-20260402T144000Z", %{
        "stage" => %{
          "plugin_id" => "clean_title",
          "start_ts" => 1_743_609_600,
          "end_ts" => 1_743_609_601
        },
        "artifacts" => [],
        "item_metadata" => %{"title" => "Cleaned"}
      })

      assert MetadataManager.get_latest(root, "title") == "Cleaned"
    end

    test "returns nil for missing key", %{root: root} do
      assert MetadataManager.get_latest(root, "nonexistent") == nil
    end
  end

  describe "get_all/2" do
    test "returns all values for a key across stages", %{root: root} do
      write_artifact_json(root, "input-20260402T143000Z", %{
        "stage" => %{
          "plugin_id" => "input",
          "start_ts" => 1_743_609_000,
          "end_ts" => 1_743_609_001
        },
        "artifacts" => [],
        "item_metadata" => %{"title" => "Input Title"}
      })

      write_artifact_json(root, "clean_title-20260402T144000Z", %{
        "stage" => %{
          "plugin_id" => "clean_title",
          "start_ts" => 1_743_609_600,
          "end_ts" => 1_743_609_601
        },
        "artifacts" => [],
        "item_metadata" => %{"title" => "Clean Title"}
      })

      result = MetadataManager.get_all(root, "title")
      assert result["input"] == "Input Title"
      assert result["clean_title"] == "Clean Title"
    end
  end

  describe "get_from/3" do
    test "returns value from a specific stage", %{root: root} do
      write_artifact_json(root, "download-20260402T143005Z", %{
        "stage" => %{
          "plugin_id" => "download",
          "start_ts" => 1_743_609_005,
          "end_ts" => 1_743_609_060
        },
        "artifacts" => [],
        "item_metadata" => %{"content_type" => "article"}
      })

      assert MetadataManager.get_from(root, "download", "content_type") == "article"
    end

    test "returns nil for missing stage", %{root: root} do
      assert MetadataManager.get_from(root, "nonexistent", "title") == nil
    end
  end
end
