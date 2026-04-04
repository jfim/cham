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
end
