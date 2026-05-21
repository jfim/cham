defmodule Cham.Pipeline.OrchestratorTest do
  use Cham.DataCase

  alias Cham.Items
  alias Cham.Pipeline.Orchestrator
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

  defp now_truncated do
    DateTime.utc_now() |> DateTime.truncate(:second)
  end

  defp create_bootstrapping_item_with_path(url, opts) do
    title = Keyword.get(opts, :title)
    tmp_dir = Keyword.get(opts, :tmp_dir)
    bootstrap_dir = Path.join(tmp_dir, "bootstrap_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(bootstrap_dir, "processing"))

    attrs = %{url: url, status: "bootstrapping"}
    attrs = if title, do: Map.put(attrs, :title, title), else: attrs

    {:ok, item} = Items.create_item(attrs)
    {:ok, item} = Items.update_item(item, %{bootstrap_path: bootstrap_dir})
    item
  end

  describe "kick_off/2" do
    test "enqueues ready stages for a new item", %{orchestrator: orchestrator} do
      {:ok, item} =
        Items.create_item(%{
          url: "https://example.com/kick-#{System.unique_integer([:positive])}",
          slug: "kick-#{System.unique_integer([:positive])}",
          status: "processing"
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
          slug: "dup-#{System.unique_integer([:positive])}",
          status: "processing"
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

  describe "fallback bootstrap selection" do
    setup do
      registry_name = :"fallback_registry_#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        Registry.start_link(
          name: registry_name,
          plugin_order: ["old_fallback", "new_fallback"]
        )

      :ok = Registry.register_plugin(registry_name, Cham.TestPlugins.OldFallbackPlugin, %{})
      :ok = Registry.register_plugin(registry_name, Cham.TestPlugins.NewFallbackPlugin, %{})

      orchestrator_name = :"fallback_orchestrator_#{System.unique_integer([:positive])}"

      {:ok, orchestrator_pid} =
        Orchestrator.start_link(
          name: orchestrator_name,
          registry: registry_name,
          recovery_interval: :infinity
        )

      Ecto.Adapters.SQL.Sandbox.allow(Cham.Repo, self(), orchestrator_pid)
      :sys.get_state(orchestrator_name)

      # Point the pipeline config at the new fallback for the duration of the test.
      previous =
        case Cham.Config.Manager.read_raw("pipeline") do
          {:ok, raw} -> raw
          _ -> %{}
        end

      :ok = Cham.Config.Manager.write_all("pipeline", %{fallback_bootstrap_stage: "new_fallback"})
      on_exit(fn -> Cham.Config.Manager.write_all("pipeline", previous) end)

      %{orchestrator: orchestrator_name}
    end

    test "uses configured fallback even when prior fallback has stale executions",
         %{orchestrator: orchestrator} do
      {:ok, item} =
        Items.create_item(%{
          url: "https://example.com/swap-#{System.unique_integer([:positive])}",
          status: "bootstrapping"
        })

      {:ok, _} =
        Items.create_artifact(%{
          item_id: item.id,
          stage: "input",
          labels: %{"domain" => "example.com", "url" => item.url},
          filenames: [],
          path: "processing/input-stale",
          status: "produced"
        })

      # Simulate a leftover StageExecution row from when old_fallback was the
      # configured fallback. Without the fix, the orchestrator treats this as
      # "the item already bootstrapped" and skips the new fallback.
      Repo.insert!(%Cham.JobTracking.StageExecution{
        item_id: item.id,
        stage: "old_fallback",
        status: "completed",
        started_at: now_truncated(),
        ended_at: now_truncated()
      })

      Orchestrator.kick_off(orchestrator, item.id)
      :sys.get_state(orchestrator)

      jobs = oban_jobs_for_item(item.id)
      plugin_ids = Enum.map(jobs, & &1.args["plugin_id"])

      assert "new_fallback" in plugin_ids,
             "expected new_fallback to be enqueued, got #{inspect(plugin_ids)}"

      refute "old_fallback" in plugin_ids
    end

    test "does not add fallback after a specialized bootstrap stage has completed" do
      registry_name = :"specialized_registry_#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        Registry.start_link(
          name: registry_name,
          plugin_order: ["specialized_bootstrap", "new_fallback"]
        )

      :ok =
        Registry.register_plugin(
          registry_name,
          Cham.TestPlugins.SpecializedBootstrapPlugin,
          %{}
        )

      :ok = Registry.register_plugin(registry_name, Cham.TestPlugins.NewFallbackPlugin, %{})

      orchestrator_name = :"specialized_orchestrator_#{System.unique_integer([:positive])}"

      {:ok, orchestrator_pid} =
        Orchestrator.start_link(
          name: orchestrator_name,
          registry: registry_name,
          recovery_interval: :infinity
        )

      Ecto.Adapters.SQL.Sandbox.allow(Cham.Repo, self(), orchestrator_pid)
      :sys.get_state(orchestrator_name)

      previous =
        case Cham.Config.Manager.read_raw("pipeline") do
          {:ok, raw} -> raw
          _ -> %{}
        end

      :ok =
        Cham.Config.Manager.write_all("pipeline", %{fallback_bootstrap_stage: "new_fallback"})

      on_exit(fn -> Cham.Config.Manager.write_all("pipeline", previous) end)

      url = "https://example.com/special-#{System.unique_integer([:positive])}"

      {:ok, item} = Items.create_item(%{url: url, status: "bootstrapping"})

      {:ok, _input} =
        Items.create_artifact(%{
          item_id: item.id,
          stage: "input",
          labels: %{"domain" => "example.com", "url" => url},
          filenames: [],
          path: "processing/input-special",
          status: "produced"
        })

      # Simulate the specialized bootstrap stage having run: produced its
      # original artifact, written the derived marker that flips its
      # can_process? to :not_applicable, and recorded a completed execution.
      {:ok, _produced} =
        Items.create_artifact(%{
          item_id: item.id,
          stage: "specialized_bootstrap",
          labels: %{"origin" => "original", "type" => "initial_download", "format" => "special"},
          filenames: ["payload.bin"],
          path: "processing/specialized_bootstrap-done",
          status: "produced"
        })

      {:ok, _marker} =
        Items.create_artifact(%{
          item_id: item.id,
          stage: "specialized_bootstrap",
          labels: %{"origin" => "derived", "type" => "specialized_marker"},
          filenames: [],
          path: "processing/specialized_bootstrap-done",
          status: "produced"
        })

      Repo.insert!(%Cham.JobTracking.StageExecution{
        item_id: item.id,
        stage: "specialized_bootstrap",
        status: "completed",
        started_at: now_truncated(),
        ended_at: now_truncated()
      })

      Orchestrator.kick_off(orchestrator_name, item.id)
      :sys.get_state(orchestrator_name)

      jobs = oban_jobs_for_item(item.id)
      plugin_ids = Enum.map(jobs, & &1.args["plugin_id"])

      refute "new_fallback" in plugin_ids,
             "expected new_fallback NOT to be enqueued after specialized bootstrap completed, got #{inspect(plugin_ids)}"
    end
  end

  describe "stage_failed/4" do
    test "marks bootstrapping item as failed when original-producing stage fails" do
      # Need a registry with an original-producing stage (EchoStage via PluginEcho)
      registry_name = :"fail_registry_#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        Registry.start_link(name: registry_name, plugin_order: ["plugin_echo"])

      :ok = Registry.register_plugin(registry_name, Cham.TestPlugins.PluginEcho, %{})

      # Start orchestrator BEFORE creating the item so recovery doesn't pick it up
      orchestrator_name = :"fail_orchestrator_#{System.unique_integer([:positive])}"

      {:ok, orchestrator_pid} =
        Orchestrator.start_link(
          name: orchestrator_name,
          registry: registry_name,
          recovery_interval: :infinity
        )

      Ecto.Adapters.SQL.Sandbox.allow(Cham.Repo, self(), orchestrator_pid)
      # Ensure the recovery continue has completed before we create the item
      :sys.get_state(orchestrator_name)

      {:ok, item} =
        Items.create_item(%{
          url: "https://example.com/fail-orig-#{System.unique_integer([:positive])}",
          status: "bootstrapping"
        })

      # Insert a failed StageExecution for the original-producing stage
      Repo.insert!(%Cham.JobTracking.StageExecution{
        item_id: item.id,
        stage: "plugin_echo",
        status: "failed",
        started_at: now_truncated(),
        ended_at: now_truncated(),
        error: "download failed"
      })

      Orchestrator.stage_failed(orchestrator_name, item.id, "plugin_echo", "download failed")
      :sys.get_state(orchestrator_name)

      updated = Items.get_item!(item.id)
      assert updated.status == "failed"
      assert updated.error_message == "original stage failed"
    end

    test "does not mark item failed when a failed stage later completed on retry" do
      registry_name = :"retry_registry_#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        Registry.start_link(name: registry_name, plugin_order: ["plugin_echo"])

      :ok = Registry.register_plugin(registry_name, Cham.TestPlugins.PluginEcho, %{})

      orchestrator_name = :"retry_orchestrator_#{System.unique_integer([:positive])}"

      {:ok, orchestrator_pid} =
        Orchestrator.start_link(
          name: orchestrator_name,
          registry: registry_name,
          recovery_interval: :infinity
        )

      Ecto.Adapters.SQL.Sandbox.allow(Cham.Repo, self(), orchestrator_pid)
      :sys.get_state(orchestrator_name)

      tmp_dir = Path.join(System.tmp_dir!(), "retry_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)
      Application.put_env(:cham, :archive_root, tmp_dir)
      on_exit(fn -> Application.delete_env(:cham, :archive_root) end)

      item =
        create_bootstrapping_item_with_path(
          "https://example.com/retry-ok-#{System.unique_integer([:positive])}",
          title: "Retry Test",
          tmp_dir: tmp_dir
        )

      # Attempt 1 failed, attempt 2 completed — mirrors a transient yt-dlp
      # download error that succeeded on retry.
      Repo.insert!(%Cham.JobTracking.StageExecution{
        item_id: item.id,
        stage: "plugin_echo",
        status: "failed",
        attempt: 1,
        started_at: now_truncated(),
        ended_at: now_truncated(),
        error: "transient"
      })

      Repo.insert!(%Cham.JobTracking.StageExecution{
        item_id: item.id,
        stage: "plugin_echo",
        status: "completed",
        attempt: 2,
        started_at: now_truncated(),
        ended_at: now_truncated()
      })

      Orchestrator.stage_failed(orchestrator_name, item.id, "plugin_echo", "transient")
      :sys.get_state(orchestrator_name)

      updated = Items.get_item!(item.id)
      refute updated.status == "failed"
      refute updated.error_message == "original stage failed"
    end

    test "does not mark item failed when artifact is produced before completed StageExecution row lands" do
      registry_name = :"race_registry_#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        Registry.start_link(name: registry_name, plugin_order: ["plugin_echo"])

      :ok = Registry.register_plugin(registry_name, Cham.TestPlugins.PluginEcho, %{})

      orchestrator_name = :"race_orchestrator_#{System.unique_integer([:positive])}"

      {:ok, orchestrator_pid} =
        Orchestrator.start_link(
          name: orchestrator_name,
          registry: registry_name,
          recovery_interval: :infinity
        )

      Ecto.Adapters.SQL.Sandbox.allow(Cham.Repo, self(), orchestrator_pid)
      :sys.get_state(orchestrator_name)

      tmp_dir = Path.join(System.tmp_dir!(), "race_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)
      Application.put_env(:cham, :archive_root, tmp_dir)
      on_exit(fn -> Application.delete_env(:cham, :archive_root) end)

      item =
        create_bootstrapping_item_with_path(
          "https://example.com/race-#{System.unique_integer([:positive])}",
          title: "Race Test",
          tmp_dir: tmp_dir
        )

      # Reproduces the production race: StageWorker writes the artifact row
      # synchronously, but the StageExecution "completed" row is written by the
      # async Tracker, which may not have processed the PubSub event by the
      # time the orchestrator runs check_transitions. Only the failed attempt-1
      # row exists in stage_executions; the artifact is already on disk.
      Repo.insert!(%Cham.JobTracking.StageExecution{
        item_id: item.id,
        stage: "plugin_echo",
        status: "failed",
        attempt: 1,
        started_at: now_truncated(),
        ended_at: now_truncated(),
        error: "transient"
      })

      {:ok, _artifact} =
        Items.create_artifact(%{
          item_id: item.id,
          stage: "plugin_echo",
          labels: %{"origin" => "original", "format" => "text"},
          filenames: ["output.txt"],
          path: "processing/plugin_echo-20260501",
          status: "produced"
        })

      Orchestrator.stage_failed(orchestrator_name, item.id, "plugin_echo", "transient")
      :sys.get_state(orchestrator_name)

      updated = Items.get_item!(item.id)
      refute updated.status == "failed"
      refute updated.error_message == "original stage failed"
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

  describe "bootstrap to archive transition" do
    test "transitions bootstrapping item to processing when all originals complete", %{
      orchestrator: orchestrator
    } do
      # Neither PluginA nor PluginB produces originals, so all_originals_complete?
      # returns true (vacuous truth). A bootstrapping item with a bootstrap_path
      # should transition to processing via archive.
      tmp_dir = Path.join(System.tmp_dir!(), "orch_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      Application.put_env(:cham, :archive_root, tmp_dir)
      on_exit(fn -> Application.delete_env(:cham, :archive_root) end)

      item =
        create_bootstrapping_item_with_path(
          "https://example.com/bootstrap-#{System.unique_integer([:positive])}",
          title: "My Test Article",
          tmp_dir: tmp_dir
        )

      # Trigger stage_completed which checks transitions
      Orchestrator.stage_completed(orchestrator, item.id, "some_stage")
      :sys.get_state(orchestrator)

      updated = Items.get_item!(item.id)
      assert updated.status == "processing"
      assert updated.archive_path != nil
      assert updated.slug != nil
      assert updated.bootstrap_path == nil
      # Slug should contain the title slugified + 6-char ID suffix
      assert String.contains?(updated.slug, "my-test-article")
    end
  end

  describe "slug generation" do
    test "generates slug from title with special characters removed", %{
      orchestrator: orchestrator
    } do
      tmp_dir = Path.join(System.tmp_dir!(), "slug_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      Application.put_env(:cham, :archive_root, tmp_dir)
      on_exit(fn -> Application.delete_env(:cham, :archive_root) end)

      item =
        create_bootstrapping_item_with_path(
          "https://example.com/slug1-#{System.unique_integer([:positive])}",
          title: "Hello, World! This is a (Test) Article #42",
          tmp_dir: tmp_dir
        )

      Orchestrator.stage_completed(orchestrator, item.id, "trigger")
      :sys.get_state(orchestrator)

      updated = Items.get_item!(item.id)
      id_suffix = String.slice(item.id, 0, 6)

      # Special chars removed, lowercased, spaces become hyphens, 6-char ID suffix
      assert updated.slug == "hello-world-this-is-a-test-article-42-#{id_suffix}"
    end

    test "falls back to URL when no title is set", %{orchestrator: orchestrator} do
      tmp_dir = Path.join(System.tmp_dir!(), "slug_url_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      Application.put_env(:cham, :archive_root, tmp_dir)
      on_exit(fn -> Application.delete_env(:cham, :archive_root) end)

      item =
        create_bootstrapping_item_with_path(
          "https://example.com/some/path",
          tmp_dir: tmp_dir
        )

      Orchestrator.stage_completed(orchestrator, item.id, "trigger")
      :sys.get_state(orchestrator)

      updated = Items.get_item!(item.id)
      id_suffix = String.slice(item.id, 0, 6)

      # URL slugified: "https://example.com/some/path" -> non-alnum chars removed
      # The slugify function removes everything except a-z, 0-9, spaces, hyphens
      # So colons, slashes, dots are removed: "httpsexamplecomsomepath"
      assert updated.slug == "httpsexamplecomsomepath-#{id_suffix}"
    end
  end

  describe "terminal state transitions" do
    test "processing item becomes complete when all stages done and no failures", %{
      orchestrator: orchestrator
    } do
      {:ok, item} =
        Items.create_item(%{
          url: "https://example.com/complete-#{System.unique_integer([:positive])}",
          status: "processing"
        })

      # A completed artifact exists
      {:ok, _} =
        Items.create_artifact(%{
          item_id: item.id,
          stage: "plugin_a",
          labels: %{"origin" => "derived", "type" => "summary"},
          filenames: [],
          path: "archive/plugin_a-20260404T000000Z",
          status: "produced"
        })

      # No active Oban jobs, no failed StageExecutions
      Orchestrator.stage_completed(orchestrator, item.id, "plugin_a")
      :sys.get_state(orchestrator)

      updated = Items.get_item!(item.id)
      assert updated.status == "complete"
    end

    test "processing item with only synthetic input artifact becomes incomplete, not complete",
         %{orchestrator: orchestrator} do
      {:ok, item} =
        Items.create_item(%{
          url: "https://example.com/no-output-#{System.unique_integer([:positive])}",
          status: "processing"
        })

      # Only the synthetic 'input' artifact exists — no real stage produced output.
      {:ok, _} =
        Items.create_artifact(%{
          item_id: item.id,
          stage: "input",
          labels: %{"url" => item.url},
          filenames: [],
          path: "archive/input",
          status: "produced"
        })

      Orchestrator.stage_completed(orchestrator, item.id, "input")
      :sys.get_state(orchestrator)

      updated = Items.get_item!(item.id)
      assert updated.status == "incomplete"
      assert updated.error_message =~ "no pipeline stages produced output"
    end

    test "transitioning to complete clears a stale error_message from a prior failure",
         %{orchestrator: orchestrator} do
      {:ok, item} =
        Items.create_item(%{
          url: "https://example.com/cleared-#{System.unique_integer([:positive])}",
          status: "processing",
          error_message: "previous failure that should be cleared"
        })

      {:ok, _} =
        Items.create_artifact(%{
          item_id: item.id,
          stage: "plugin_a",
          labels: %{"origin" => "derived", "type" => "summary"},
          filenames: [],
          path: "archive/plugin_a-20260404T000000Z",
          status: "produced"
        })

      Orchestrator.stage_completed(orchestrator, item.id, "plugin_a")
      :sys.get_state(orchestrator)

      updated = Items.get_item!(item.id)
      assert updated.status == "complete"
      assert is_nil(updated.error_message)
    end

    test "processing item becomes incomplete when some stages failed", %{
      orchestrator: orchestrator
    } do
      {:ok, item} =
        Items.create_item(%{
          url: "https://example.com/incomplete-#{System.unique_integer([:positive])}",
          status: "processing"
        })

      # A completed artifact exists
      {:ok, _} =
        Items.create_artifact(%{
          item_id: item.id,
          stage: "plugin_a",
          labels: %{"origin" => "derived", "type" => "summary"},
          filenames: [],
          path: "archive/plugin_a-20260404T000000Z",
          status: "produced"
        })

      # A failed stage execution exists
      Repo.insert!(%Cham.JobTracking.StageExecution{
        item_id: item.id,
        stage: "plugin_b",
        status: "failed",
        started_at: now_truncated(),
        ended_at: now_truncated(),
        error: "gpu timeout"
      })

      Orchestrator.stage_failed(orchestrator, item.id, "plugin_b", "gpu timeout")
      :sys.get_state(orchestrator)

      updated = Items.get_item!(item.id)
      assert updated.status == "incomplete"
    end
  end

  describe "recovery" do
    test "recovers stalled items on startup" do
      # Create an item in processing state with ready stages but no active jobs
      {:ok, item} =
        Items.create_item(%{
          url: "https://example.com/stalled-#{System.unique_integer([:positive])}",
          status: "processing"
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

      # Start a new orchestrator which should recover the stalled item on init
      registry_name = :"recovery_registry_#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        Registry.start_link(name: registry_name, plugin_order: ["plugin_a", "plugin_b"])

      :ok = Registry.register_plugin(registry_name, Cham.TestPlugins.PluginA, %{})
      :ok = Registry.register_plugin(registry_name, Cham.TestPlugins.PluginB, %{})

      orchestrator_name = :"recovery_orchestrator_#{System.unique_integer([:positive])}"

      {:ok, orchestrator_pid} =
        Orchestrator.start_link(
          name: orchestrator_name,
          registry: registry_name,
          recovery_interval: :infinity
        )

      Ecto.Adapters.SQL.Sandbox.allow(Cham.Repo, self(), orchestrator_pid)

      # Wait for the :recover continue to process
      :sys.get_state(orchestrator_name)

      # The stalled item should now have an enqueued job
      jobs = oban_jobs_for_item(item.id)
      assert length(jobs) >= 1
      assert Enum.any?(jobs, fn j -> j.args["plugin_id"] == "plugin_a" end)
    end
  end
end
