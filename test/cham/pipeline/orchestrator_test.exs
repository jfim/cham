defmodule Cham.Pipeline.OrchestratorTest do
  use Cham.DataCase

  alias Cham.Pipeline.Orchestrator
  alias Cham.Items
  alias Cham.Plugin.Registry

  setup do
    registry_name = :"test_registry_#{System.unique_integer([:positive])}"
    {:ok, _pid} = Registry.start_link(name: registry_name, plugin_order: ["plugin_a", "plugin_b"])
    :ok = Registry.register_plugin(registry_name, Cham.TestPlugins.PluginA, %{})
    :ok = Registry.register_plugin(registry_name, Cham.TestPlugins.PluginB, %{})

    orchestrator_name = :"test_orchestrator_#{System.unique_integer([:positive])}"

    {:ok, orchestrator_pid} =
      Orchestrator.start_link(
        name: orchestrator_name,
        registry: registry_name,
        recovery_interval: :infinity
      )

    # Allow the orchestrator process to use the sandbox connection
    Ecto.Adapters.SQL.Sandbox.allow(Cham.Repo, self(), orchestrator_pid)

    %{orchestrator: orchestrator_name, registry: registry_name}
  end

  defp oban_jobs_for_item(item_id) do
    Repo.all(
      from j in "oban_jobs",
        where:
          j.worker == "Cham.Pipeline.StageWorker" and
            fragment("?->>'item_id' = ?", j.args, ^item_id),
        select: %{
          id: j.id,
          state: j.state,
          worker: j.worker,
          args: j.args
        }
    )
  end

  describe "kick_off/2" do
    test "enqueues ready stages for a new item", %{orchestrator: orchestrator} do
      {:ok, item} =
        Items.create_item(%{
          url: "https://example.com/kick-#{System.unique_integer([:positive])}",
          slug: "kick-#{System.unique_integer([:positive])}"
        })

      {:ok, _} =
        Items.create_artifact(%{
          item_id: item.id,
          stage: "input",
          labels: %{"origin" => "original", "format" => "text"},
          filenames: [],
          path: "processing/input-20260404T000000Z",
          status: "produced"
        })

      Orchestrator.kick_off(orchestrator, item.id)
      # Synchronize — wait for the cast to be processed
      :sys.get_state(orchestrator)

      jobs = oban_jobs_for_item(item.id)
      assert [job] = jobs
      assert job.args["item_id"] == item.id
      assert job.args["plugin_id"] == "plugin_a"
    end

    test "does not enqueue stages for terminal items", %{orchestrator: orchestrator} do
      {:ok, item} =
        Items.create_item(%{
          url: "https://example.com/done-#{System.unique_integer([:positive])}",
          slug: "done-#{System.unique_integer([:positive])}",
          status: "complete"
        })

      Orchestrator.kick_off(orchestrator, item.id)
      :sys.get_state(orchestrator)

      assert [] = oban_jobs_for_item(item.id)
    end

    test "does not enqueue already-running stages", %{orchestrator: orchestrator} do
      {:ok, item} =
        Items.create_item(%{
          url: "https://example.com/dup-#{System.unique_integer([:positive])}",
          slug: "dup-#{System.unique_integer([:positive])}"
        })

      {:ok, _} =
        Items.create_artifact(%{
          item_id: item.id,
          stage: "input",
          labels: %{"origin" => "original", "format" => "text"},
          filenames: [],
          path: "processing/input-20260404T000000Z",
          status: "produced"
        })

      # First kick_off enqueues the stage
      Orchestrator.kick_off(orchestrator, item.id)
      :sys.get_state(orchestrator)

      jobs = oban_jobs_for_item(item.id)
      assert length(jobs) == 1, "Expected 1 job but got #{length(jobs)} for item #{item.id}"

      # Second kick_off should not duplicate (active job excluded)
      Orchestrator.kick_off(orchestrator, item.id)
      :sys.get_state(orchestrator)

      jobs = oban_jobs_for_item(item.id)
      assert length(jobs) == 1
    end
  end

  describe "stage_completed/3" do
    test "does not enqueue stages when no new inputs available", %{orchestrator: orchestrator} do
      {:ok, item} =
        Items.create_item(%{
          url: "https://example.com/next-#{System.unique_integer([:positive])}",
          slug: "next-#{System.unique_integer([:positive])}",
          status: "processing"
        })

      # Create artifacts that satisfy StageA's inputs (already completed)
      {:ok, _} =
        Items.create_artifact(%{
          item_id: item.id,
          stage: "input",
          labels: %{"origin" => "original", "format" => "text"},
          filenames: [],
          path: "processing/input-20260404T000000Z",
          status: "produced"
        })

      # Mark StageA as already completed via artifact
      {:ok, _} =
        Items.create_artifact(%{
          item_id: item.id,
          stage: "plugin_a",
          labels: %{"origin" => "derived", "type" => "summary"},
          filenames: [],
          path: "processing/plugin_a-20260404T000000Z",
          status: "produced"
        })

      Orchestrator.stage_completed(orchestrator, item.id, "plugin_a")
      :sys.get_state(orchestrator)

      # StageA is already done, StageB needs audio input which doesn't exist
      # So no new stages should be enqueued
      assert [] = oban_jobs_for_item(item.id)
    end
  end
end
