defmodule Cham.JobTracking.TrackerTest do
  use Cham.DataCase

  alias Cham.JobTracking.{StageExecution, Tracker}

  alias Cham.Pipeline.Events.{
    StageCompleted,
    StageFailed,
    StageProgress,
    StageStarted
  }

  alias Cham.Repo

  alias Cham.Items

  setup do
    name = :"tracker_#{:erlang.unique_integer([:positive])}"
    start_supervised!({Tracker, name: name})

    {:ok, item} =
      Items.create_item(%{
        url: "https://example.com/track-#{:erlang.unique_integer([:positive])}"
      })

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

  describe "startup reconciliation" do
    test "marks orphaned 'started' executions as 'crashed'", %{item: item} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, orphan} =
        %StageExecution{}
        |> StageExecution.changeset(%{
          item_id: item.id,
          stage: "auto_tag",
          status: "started",
          attempt: 1,
          started_at: now
        })
        |> Repo.insert()

      count = Tracker.reconcile_orphaned_executions()
      assert count >= 1

      reloaded = Repo.get!(StageExecution, orphan.id)
      assert reloaded.status == "crashed"
      assert reloaded.ended_at != nil
      assert reloaded.error =~ "reconciled at startup"
    end

    test "moves processing items with orphaned executions to incomplete", %{item: item} do
      {:ok, item} = Items.update_item(item, %{status: "processing"})
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      %StageExecution{}
      |> StageExecution.changeset(%{
        item_id: item.id,
        stage: "transcribe",
        status: "started",
        attempt: 1,
        started_at: now
      })
      |> Repo.insert!()

      Tracker.reconcile_orphaned_executions()

      assert Items.get_item!(item.id).status == "incomplete"
    end

    test "leaves already-terminal items alone", %{item: item} do
      {:ok, item} = Items.update_item(item, %{status: "complete"})
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      %StageExecution{}
      |> StageExecution.changeset(%{
        item_id: item.id,
        stage: "transcribe",
        status: "started",
        attempt: 1,
        started_at: now
      })
      |> Repo.insert!()

      Tracker.reconcile_orphaned_executions()

      assert Items.get_item!(item.id).status == "complete"
    end

    test "does not touch non-started executions", %{item: item} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, completed} =
        %StageExecution{}
        |> StageExecution.changeset(%{
          item_id: item.id,
          stage: "extract",
          status: "completed",
          attempt: 1,
          started_at: now,
          ended_at: now,
          duration_ms: 10
        })
        |> Repo.insert()

      Tracker.reconcile_orphaned_executions()

      reloaded = Repo.get!(StageExecution, completed.id)
      assert reloaded.status == "completed"
    end
  end

  describe "oban exception telemetry" do
    test "publishes StageFailed when StageWorker job raises", %{item: item} do
      Cham.EventBus.subscribe("pipeline")

      job = %Oban.Job{
        worker: "Cham.Pipeline.StageWorker",
        args: %{"item_id" => item.id, "plugin_id" => "auto_tag"},
        attempt: 2
      }

      metadata = %{
        job: job,
        kind: :error,
        reason: %RuntimeError{message: "boom"},
        stacktrace: []
      }

      Tracker.handle_oban_exception(
        [:oban, :job, :exception],
        %{duration: 0},
        metadata,
        nil
      )

      assert_receive %StageFailed{
        stage_id: "auto_tag",
        item_id: received_id,
        attempt: 2,
        error: err
      }

      assert received_id == item.id
      assert err =~ "boom"
    end

    test "ignores non-StageWorker jobs" do
      Cham.EventBus.subscribe("pipeline")

      job = %Oban.Job{
        worker: "Some.Other.Worker",
        args: %{},
        attempt: 1
      }

      metadata = %{job: job, kind: :error, reason: :whatever, stacktrace: []}

      Tracker.handle_oban_exception(
        [:oban, :job, :exception],
        %{duration: 0},
        metadata,
        nil
      )

      refute_receive %StageFailed{}, 50
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
