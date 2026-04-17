defmodule Cham.JobTracking.TrackerTest do
  use Cham.DataCase

  alias Cham.JobTracking.Tracker

  alias Cham.Pipeline.Events.{
    StageStarted,
    StageCompleted,
    StageFailed,
    StageProgress
  }

  alias Cham.Items

  setup do
    name = :"tracker_#{:erlang.unique_integer([:positive])}"
    start_supervised!({Tracker, name: name})

    {:ok, item} =
      Items.create_item(%{url: "https://example.com/track-#{:erlang.unique_integer([:positive])}"})

    %{tracker: name, item: item}
  end

  describe "stage execution recording" do
    test "records StageStarted event", %{item: item} do
      Cham.EventBus.publish("pipeline:stage_started", %StageStarted{
        stage_id: "transcribe",
        item_id: item.id,
        attempt: 1
      })

      Process.sleep(50)

      history = Tracker.get_stage_history(item.id)
      assert length(history) == 1
      assert hd(history).stage == "transcribe"
      assert hd(history).status == "started"
    end

    test "records StageCompleted event", %{item: item} do
      Cham.EventBus.publish("pipeline:stage_started", %StageStarted{
        stage_id: "transcribe",
        item_id: item.id,
        attempt: 1
      })

      Process.sleep(50)

      Cham.EventBus.publish("pipeline:stage_completed", %StageCompleted{
        stage_id: "transcribe",
        item_id: item.id,
        duration_ms: 1500
      })

      Process.sleep(50)

      history = Tracker.get_stage_history(item.id)
      completed = Enum.find(history, &(&1.status == "completed"))
      assert completed != nil
      assert completed.duration_ms == 1500
    end

    test "records StageFailed event", %{item: item} do
      Cham.EventBus.publish("pipeline:stage_started", %StageStarted{
        stage_id: "summarize",
        item_id: item.id,
        attempt: 1
      })

      Process.sleep(50)

      Cham.EventBus.publish("pipeline:stage_failed", %StageFailed{
        stage_id: "summarize",
        item_id: item.id,
        error: "model not available",
        attempt: 3
      })

      Process.sleep(50)

      history = Tracker.get_stage_history(item.id)
      failed = Enum.find(history, &(&1.status == "failed"))
      assert failed.error == "model not available"
    end
  end

  describe "ephemeral progress" do
    test "tracks and returns progress for active stages", %{tracker: name, item: item} do
      Cham.EventBus.publish("pipeline:stage_progress", %StageProgress{
        stage_id: "transcribe",
        item_id: item.id,
        progress: 0.45,
        message: "2m30s of 10m"
      })

      Process.sleep(50)

      progress = Tracker.get_progress(name, item.id)
      assert progress["transcribe"].progress == 0.45
      assert progress["transcribe"].message == "2m30s of 10m"
    end

    test "clears progress on stage completion", %{tracker: name, item: item} do
      Cham.EventBus.publish("pipeline:stage_progress", %StageProgress{
        stage_id: "transcribe",
        item_id: item.id,
        progress: 0.5,
        message: "halfway"
      })

      Process.sleep(50)

      Cham.EventBus.publish("pipeline:stage_completed", %StageCompleted{
        stage_id: "transcribe",
        item_id: item.id,
        duration_ms: 100
      })

      Process.sleep(50)

      progress = Tracker.get_progress(name, item.id)
      assert progress == %{}
    end
  end
end
