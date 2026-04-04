defmodule Cham.Pipeline.StageWorkerTest do
  use Cham.DataCase

  alias Cham.Pipeline.StageWorker
  alias Cham.Items
  alias Cham.Pipeline.Events.{StageStarted, StageCompleted}

  setup do
    tmp = Path.join(System.tmp_dir!(), "cham_worker_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, item} = Items.create_item(%{url: "https://example.com/test"})

    # Create an input artifact in the DB
    {:ok, input_artifact} =
      Items.create_artifact(%{
        item_id: item.id,
        stage: "input",
        path: "processing/input-20260404T120000Z",
        labels: %{"domain" => "example.com"},
        status: "produced"
      })

    %{item: item, tmp: tmp, input_artifact: input_artifact}
  end

  describe "execute_stage/4" do
    test "runs a stage, writes artifact.json, and records artifacts in DB", %{
      item: item,
      tmp: tmp
    } do
      item_dir = Path.join(tmp, "item")
      File.mkdir_p!(Path.join(item_dir, "processing"))

      Cham.EventBus.subscribe("pipeline")

      result =
        StageWorker.execute_stage(
          Cham.TestPlugins.EchoStage,
          "echo_stage",
          item,
          item_dir
        )

      assert {:ok, _stage_dir} = result

      # Verify artifact.json was written
      {:ok, state} = Cham.Archive.MetadataManager.merge_item_state(item_dir)
      assert length(state.artifacts) == 1
      assert hd(state.artifacts)["labels"]["origin"] == "original"

      # Verify artifacts recorded in DB
      artifacts = Items.list_artifacts(item.id)
      # input artifact + new artifact
      assert length(artifacts) == 2

      new_artifact = Enum.find(artifacts, &(&1.stage == "echo_stage"))
      assert new_artifact.labels["format"] == "text"
      assert new_artifact.status == "produced"

      # Verify events published
      assert_receive %StageStarted{stage_id: "echo_stage", item_id: _}
      assert_receive %StageCompleted{stage_id: "echo_stage", item_id: _}
    end
  end

  describe "resolve_inputs/3" do
    test "prepends item_dir to artifact path" do
      {:ok, item} =
        Items.create_item(%{
          url: "https://example.com/resolve-#{System.unique_integer([:positive])}",
          slug: "resolve-#{System.unique_integer([:positive])}"
        })

      {:ok, _artifact} =
        Items.create_artifact(%{
          item_id: item.id,
          stage: "test_stage",
          labels: %{"origin" => "original", "format" => "text"},
          filenames: ["file.txt"],
          path: "processing/test_stage-20260404T000000Z",
          status: "produced"
        })

      result = StageWorker.resolve_inputs(Cham.TestPlugins.StageA, item.id, "/tmp/item_dir")

      assert [input] = result
      assert input.input_path == "/tmp/item_dir/processing/test_stage-20260404T000000Z"
      assert input.labels == %{"origin" => "original", "format" => "text"}
      assert input.filenames == ["file.txt"]
    end

    test "returns empty list when no artifacts match" do
      {:ok, item} =
        Items.create_item(%{
          url: "https://example.com/no-match",
          slug: "nomatch-#{System.unique_integer([:positive])}"
        })

      result = StageWorker.resolve_inputs(Cham.TestPlugins.StageA, item.id, "/tmp/item_dir")
      assert result == []
    end

    test "excludes non-produced artifacts" do
      {:ok, item} =
        Items.create_item(%{
          url: "https://example.com/failed",
          slug: "failed-#{System.unique_integer([:positive])}"
        })

      {:ok, _artifact} =
        Items.create_artifact(%{
          item_id: item.id,
          stage: "test_stage",
          labels: %{"origin" => "original", "format" => "text"},
          filenames: ["file.txt"],
          path: "processing/test_stage-20260404T000000Z",
          status: "failed"
        })

      result = StageWorker.resolve_inputs(Cham.TestPlugins.StageA, item.id, "/tmp/item_dir")
      assert result == []
    end
  end
end
