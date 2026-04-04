# Pipeline Orchestrator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire the pipeline together so that `Pipeline.submit_url/2` triggers a complete end-to-end processing run — from download through content extraction, transcription, summarization, tagging, and title cleanup.

**Architecture:** A new `Pipeline.Orchestrator` GenServer serializes all scheduling decisions. After each stage completes (via Oban StageWorker), the Orchestrator evaluates the DAG, enqueues next stages, and manages item lifecycle transitions (bootstrap → archive → terminal). A periodic 30-second sweep guarantees progress even if messages are lost.

**Tech Stack:** Elixir GenServer, Oban (job enqueueing), Ecto (queries), existing DAG/Registry/StageWorker modules

**Spec:** `docs/superpowers/specs/2026-04-04-pipeline-orchestrator-design.md`

---

## File Structure

```
lib/cham/pipeline/orchestrator.ex  — GenServer: scheduling, transitions, recovery (NEW)

lib/cham/pipeline/stage_worker.ex  — Add Orchestrator notifications, fix resolve_inputs, extend update_item_metadata (MODIFY)
lib/cham/pipeline.ex               — Add Orchestrator.kick_off call after submit_url (MODIFY)
lib/cham/application.ex            — Add Orchestrator to supervision tree (MODIFY)
lib/cham/items.ex                  — Add list_items with multiple statuses filter (MODIFY)

test/cham/pipeline/orchestrator_test.exs  — Unit tests (NEW)
test/cham/pipeline/stage_worker_test.exs  — Tests for modified functions (MODIFY if exists, CREATE if not)
```

---

## Task 1: Fix `resolve_inputs` to use absolute paths

**Files:**
- Modify: `lib/cham/pipeline/stage_worker.ex:109-129`
- Modify: `lib/cham/pipeline/stage_worker.ex:60` (call site)
- Test: `test/cham/pipeline/stage_worker_test.exs`

- [ ] **Step 1: Write failing test for resolve_inputs with absolute paths**

```elixir
# test/cham/pipeline/stage_worker_test.exs
defmodule Cham.Pipeline.StageWorkerTest do
  use Cham.DataCase

  alias Cham.Pipeline.StageWorker
  alias Cham.Items

  describe "resolve_inputs/3" do
    test "prepends item_dir to artifact path" do
      {:ok, item} =
        Items.create_item(%{url: "https://example.com", slug: "test-#{System.unique_integer([:positive])}"})

      {:ok, _artifact} =
        Items.create_artifact(%{
          item_id: item.id,
          stage: "test_stage",
          labels: %{"origin" => "original"},
          filenames: ["file.txt"],
          path: "processing/test_stage-20260404T000000Z",
          status: "produced"
        })

      result = StageWorker.resolve_inputs(Cham.TestPlugins.StageA, item.id, "/tmp/item_dir")

      assert [input] = result
      assert input.input_path == "/tmp/item_dir/processing/test_stage-20260404T000000Z"
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/cham/pipeline/stage_worker_test.exs`
Expected: FAIL — `resolve_inputs/3` is undefined (currently `resolve_inputs/2` is private)

- [ ] **Step 3: Update resolve_inputs to accept item_dir and prepend to path**

In `lib/cham/pipeline/stage_worker.ex`, replace `resolve_inputs/2` (lines 109-129) with a public `resolve_inputs/3`:

```elixir
  @doc """
  Resolve input artifacts for a stage module. Returns a list of input artifact maps
  with absolute paths (item_dir prepended to relative artifact path).
  """
  def resolve_inputs(stage_module, item_id, item_dir) do
    if function_exported?(stage_module, :input_matchers, 0) do
      artifacts = Items.list_artifacts(item_id)

      Enum.flat_map(stage_module.input_matchers(), fn matcher ->
        artifacts
        |> Enum.filter(fn a ->
          Cham.Pipeline.LabelMatcher.matches?(a.labels, matcher) and a.status == "produced"
        end)
        |> Enum.map(fn a ->
          %{
            labels: a.labels,
            filenames: a.filenames,
            input_path: Path.join(item_dir, a.path)
          }
        end)
      end)
    else
      []
    end
  end
```

Update the call site in `execute_stage/4` (line 60) to pass `item_dir`:

```elixir
    # Resolve input artifacts
    input_artifacts = resolve_inputs(stage_module, item.id, item_dir)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/cham/pipeline/stage_worker_test.exs`
Expected: PASS

- [ ] **Step 5: Run full test suite**

Run: `mix format && mix test`
Expected: All tests pass

- [ ] **Step 6: Commit**

```bash
git add lib/cham/pipeline/stage_worker.ex test/cham/pipeline/stage_worker_test.exs
git commit -m "fix: resolve_inputs prepends item_dir for absolute artifact paths"
```

---

## Task 2: Extend `update_item_metadata` to handle tags and metadata map

**Files:**
- Modify: `lib/cham/pipeline/stage_worker.ex:171-182`
- Test: `test/cham/pipeline/stage_worker_test.exs`

- [ ] **Step 1: Write failing test for tags and extra metadata**

Add to `test/cham/pipeline/stage_worker_test.exs`:

```elixir
  describe "update_item_metadata/2" do
    test "promotes title, content_type, and tags to item columns" do
      {:ok, item} =
        Items.create_item(%{url: "https://example.com/meta", slug: "meta-#{System.unique_integer([:positive])}"})

      result = %{
        item_metadata: %{
          "title" => "Test Title",
          "content_type" => "article",
          "tags" => ["elixir", "phoenix"]
        },
        artifacts: [],
        provenance: %{}
      }

      StageWorker.update_item_metadata(item, result)

      updated = Items.get_item!(item.id)
      assert updated.title == "Test Title"
      assert updated.content_type == "article"
      assert updated.tags == ["elixir", "phoenix"]
    end

    test "merges extra metadata into item.metadata map" do
      {:ok, item} =
        Items.create_item(%{
          url: "https://example.com/extra",
          slug: "extra-#{System.unique_integer([:positive])}",
          metadata: %{"existing" => "value"}
        })

      result = %{
        item_metadata: %{
          "title" => "Title",
          "author" => "Jane Doe",
          "duration" => 1832,
          "language" => "en"
        },
        artifacts: [],
        provenance: %{}
      }

      StageWorker.update_item_metadata(item, result)

      updated = Items.get_item!(item.id)
      assert updated.title == "Title"
      assert updated.metadata["author"] == "Jane Doe"
      assert updated.metadata["duration"] == 1832
      assert updated.metadata["language"] == "en"
      assert updated.metadata["existing"] == "value"
    end

    test "no-ops when metadata is empty" do
      {:ok, item} =
        Items.create_item(%{url: "https://example.com/empty", slug: "empty-#{System.unique_integer([:positive])}"})

      result = %{item_metadata: %{}, artifacts: [], provenance: %{}}

      StageWorker.update_item_metadata(item, result)

      updated = Items.get_item!(item.id)
      assert updated.title == nil
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/cham/pipeline/stage_worker_test.exs`
Expected: FAIL — `update_item_metadata/2` is private, and doesn't handle tags or metadata

- [ ] **Step 3: Make update_item_metadata public and extend it**

Replace `update_item_metadata/2` in `lib/cham/pipeline/stage_worker.ex` (lines 171-182):

```elixir
  @doc """
  Update item columns and metadata from stage results.
  Promotes title, content_type, tags to dedicated columns.
  Merges remaining keys into item.metadata JSON map.
  """
  def update_item_metadata(item, result) do
    meta = result[:item_metadata] || %{}
    string_meta = stringify_keys(meta)

    # Promote known fields to dedicated columns
    column_updates =
      %{}
      |> maybe_put(:title, string_meta["title"])
      |> maybe_put(:content_type, string_meta["content_type"])
      |> maybe_put(:tags, string_meta["tags"])

    # Merge everything else into item.metadata
    known_keys = ~w(title content_type tags)
    extra = Map.drop(string_meta, known_keys)

    metadata_update =
      if extra != %{} do
        %{metadata: Map.merge(item.metadata || %{}, extra)}
      else
        %{}
      end

    updates = Map.merge(column_updates, metadata_update)

    if updates != %{} do
      Items.update_item(item, updates)
    end
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/cham/pipeline/stage_worker_test.exs`
Expected: PASS

- [ ] **Step 5: Run full test suite**

Run: `mix format && mix test`
Expected: All tests pass

- [ ] **Step 6: Commit**

```bash
git add lib/cham/pipeline/stage_worker.ex test/cham/pipeline/stage_worker_test.exs
git commit -m "feat: extend update_item_metadata to handle tags and metadata map"
```

---

## Task 3: Add StageWorker notifications to Orchestrator

**Files:**
- Modify: `lib/cham/pipeline/stage_worker.ex:14-38`
- Test: existing StageWorker tests still pass

- [ ] **Step 1: Update StageWorker.perform/1 to notify Orchestrator on success**

In `lib/cham/pipeline/stage_worker.ex`, replace the `perform/1` function (lines 14-38):

```elixir
  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    item_id = args["item_id"]
    stage_module = String.to_existing_atom(args["stage_module"])
    plugin_id = args["plugin_id"]

    item = Items.get_item!(item_id)
    item_dir = resolve_item_dir(item)

    case execute_stage(stage_module, plugin_id, item, item_dir) do
      {:ok, _stage_dir} ->
        Cham.Pipeline.Orchestrator.stage_completed(item_id, plugin_id)
        :ok

      {:error, reason} ->
        {:error, reason}

      {:snooze, duration_ms, reason} ->
        Cham.EventBus.publish("pipeline:stage_snoozed", %StageSnoozed{
          stage_id: plugin_id,
          item_id: item_id,
          duration_ms: duration_ms,
          reason: reason
        })

        {:snooze, div(duration_ms, 1000)}
    end
  end
```

- [ ] **Step 2: Add after_all_retries callback for permanent failures**

Add to `lib/cham/pipeline/stage_worker.ex` after the `perform/1` function:

```elixir
  @doc """
  Called by Oban when all retry attempts are exhausted.
  Notifies the Orchestrator of permanent failure.
  """
  def after_all_retries(%Oban.Job{args: args}) do
    Cham.Pipeline.Orchestrator.stage_failed(
      args["item_id"],
      args["plugin_id"],
      "all retries exhausted"
    )
  end
```

- [ ] **Step 3: Run full test suite** (Orchestrator module doesn't exist yet, but the calls are casts that won't crash if the process isn't running in tests)

Run: `mix format && mix compile`
Expected: Compilation warning about Orchestrator module not existing — that's OK, we create it in Task 4.

Note: Don't run `mix test` yet — compile-only to verify syntax. Tests will pass after Task 4 creates the Orchestrator.

- [ ] **Step 4: Commit**

```bash
git add lib/cham/pipeline/stage_worker.ex
git commit -m "feat: StageWorker notifies Orchestrator on completion and final failure"
```

---

## Task 4: Create the Orchestrator GenServer

**Files:**
- Create: `lib/cham/pipeline/orchestrator.ex`
- Create: `test/cham/pipeline/orchestrator_test.exs`

- [ ] **Step 1: Write failing test for kick_off**

```elixir
# test/cham/pipeline/orchestrator_test.exs
defmodule Cham.Pipeline.OrchestratorTest do
  use Cham.DataCase

  alias Cham.Pipeline.Orchestrator
  alias Cham.Items
  alias Cham.Plugin.Registry

  setup do
    # Start a test registry with test plugins
    registry_name = :"test_registry_#{System.unique_integer([:positive])}"
    {:ok, _pid} = Registry.start_link(name: registry_name, plugin_order: ["plugin_a", "plugin_b"])
    :ok = Registry.register_plugin(registry_name, Cham.TestPlugins.PluginA, %{})
    :ok = Registry.register_plugin(registry_name, Cham.TestPlugins.PluginB, %{})

    # Start Orchestrator with test registry
    orchestrator_name = :"test_orchestrator_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      Orchestrator.start_link(
        name: orchestrator_name,
        registry: registry_name,
        recovery_interval: :infinity
      )

    %{orchestrator: orchestrator_name, registry: registry_name}
  end

  describe "kick_off/2" do
    test "enqueues ready stages for a new item", %{orchestrator: orchestrator} do
      {:ok, item} =
        Items.create_item(%{url: "https://example.com", slug: "test-#{System.unique_integer([:positive])}"})

      # Create input artifact with labels matching StageA (origin:original, format:text)
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

      # Give the cast time to process
      :sys.get_state(orchestrator)

      # Check that an Oban job was enqueued
      assert [job] = all_enqueued(worker: Cham.Pipeline.StageWorker)
      assert job.args["item_id"] == item.id
      assert job.args["plugin_id"] == "plugin_a"
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/cham/pipeline/orchestrator_test.exs`
Expected: Compilation error — `Cham.Pipeline.Orchestrator` not found

- [ ] **Step 3: Implement the Orchestrator GenServer**

```elixir
# lib/cham/pipeline/orchestrator.ex
defmodule Cham.Pipeline.Orchestrator do
  @moduledoc """
  GenServer that serializes pipeline scheduling decisions and item lifecycle transitions.
  After each stage completes, evaluates the DAG and enqueues next ready stages.
  Manages bootstrap → archive → terminal state transitions.
  """

  use GenServer
  require Logger

  import Ecto.Query
  alias Cham.{Items, Repo}
  alias Cham.Items.Item
  alias Cham.Pipeline.{DAG, StageWorker}
  alias Cham.Archive.ArchiveManager

  @default_recovery_interval :timer.seconds(30)

  # --- Client API ---

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def kick_off(server \\ __MODULE__, item_id) do
    GenServer.cast(server, {:kick_off, item_id})
  end

  def stage_completed(server \\ __MODULE__, item_id, plugin_id) do
    GenServer.cast(server, {:stage_completed, item_id, plugin_id})
  end

  def stage_failed(server \\ __MODULE__, item_id, plugin_id, error) do
    GenServer.cast(server, {:stage_failed, item_id, plugin_id, error})
  end

  # --- Server Callbacks ---

  @impl true
  def init(opts) do
    registry = Keyword.get(opts, :registry, Cham.Plugin.Registry)
    recovery_interval = Keyword.get(opts, :recovery_interval, @default_recovery_interval)

    state = %{registry: registry, recovery_interval: recovery_interval}

    if recovery_interval != :infinity do
      schedule_recovery(recovery_interval)
    end

    {:ok, state, {:continue, :recover}}
  end

  @impl true
  def handle_continue(:recover, state) do
    recover_stalled_items(state)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:kick_off, item_id}, state) do
    evaluate_and_enqueue(item_id, state)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:stage_completed, item_id, _plugin_id}, state) do
    evaluate_and_enqueue(item_id, state)
    check_transitions(item_id, state)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:stage_failed, item_id, plugin_id, error}, state) do
    Logger.warning("Stage #{plugin_id} permanently failed for item #{item_id}: #{error}")
    check_transitions(item_id, state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:recover, state) do
    recover_stalled_items(state)
    schedule_recovery(state.recovery_interval)
    {:noreply, state}
  end

  # --- Internal Logic ---

  defp schedule_recovery(interval) do
    Process.send_after(self(), :recover, interval)
  end

  defp recover_stalled_items(state) do
    items =
      Item
      |> where([i], i.status in ["bootstrapping", "processing"])
      |> Repo.all()

    Enum.each(items, fn item ->
      evaluate_and_enqueue(item.id, state)
      check_transitions(item.id, state)
    end)
  end

  defp evaluate_and_enqueue(item_id, state) do
    item = Items.get_item!(item_id)

    # Skip terminal items
    if item.status in ["complete", "incomplete", "failed"] do
      :ok
    else
      artifacts = Items.list_artifacts(item_id)
      stages = Cham.Plugin.Registry.get_stages(state.registry)

      excluded_ids = build_exclusion_set(item_id, artifacts)
      artifact_labels = Enum.map(artifacts, & &1.labels)

      ready_stages = DAG.find_next_stages(stages, artifact_labels, excluded_ids)

      Enum.each(ready_stages, fn stage ->
        job_args = %{
          "item_id" => item_id,
          "stage_module" => to_string(stage.module),
          "plugin_id" => stage.plugin_id
        }

        StageWorker.new(job_args, queue: stage.queue)
        |> Oban.insert()
      end)
    end
  end

  defp build_exclusion_set(item_id, artifacts) do
    # 1. Stages that have produced artifacts
    completed =
      artifacts
      |> Enum.filter(&(&1.status == "produced"))
      |> Enum.map(& &1.stage)
      |> MapSet.new()

    # 2. Stages that have permanently failed
    failed =
      Cham.JobTracking.StageExecution
      |> where([s], s.item_id == ^item_id and s.status == "failed")
      |> select([s], s.stage)
      |> Repo.all()
      |> MapSet.new()

    # 3. Stages with active Oban jobs
    active =
      Oban.Job
      |> where([j], j.worker == "Cham.Pipeline.StageWorker")
      |> where([j], j.state in ["available", "executing", "scheduled", "retryable"])
      |> where([j], fragment("args->>'item_id' = ?", ^item_id))
      |> select([j], fragment("args->>'plugin_id'"))
      |> Repo.all()
      |> MapSet.new()

    completed |> MapSet.union(failed) |> MapSet.union(active)
  end

  defp check_transitions(item_id, state) do
    item = Items.get_item!(item_id)

    cond do
      item.status == "bootstrapping" ->
        check_bootstrap_transition(item, state)

      item.status == "processing" ->
        check_terminal_transition(item, state)

      true ->
        :ok
    end
  end

  defp check_bootstrap_transition(item, state) do
    stages = Cham.Plugin.Registry.get_stages(state.registry)
    artifacts = Items.list_artifacts(item.id)

    completed_ids =
      artifacts
      |> Enum.filter(&(&1.status == "produced"))
      |> Enum.map(& &1.stage)
      |> MapSet.new()

    # Check if any original-producing stage permanently failed
    failed_stages =
      Cham.JobTracking.StageExecution
      |> where([s], s.item_id == ^item.id and s.status == "failed")
      |> select([s], s.stage)
      |> Repo.all()
      |> MapSet.new()

    original_stages = Enum.filter(stages, &produces_originals?/1)

    has_failed_original =
      Enum.any?(original_stages, fn s -> MapSet.member?(failed_stages, s.plugin_id) end)

    if has_failed_original do
      Items.update_item(item, %{status: "failed", error_message: "Bootstrap stage failed"})
    else
      if DAG.all_originals_complete?(stages, completed_ids) do
        transition_to_archive(item, state)
      end
    end
  end

  defp transition_to_archive(item, state) do
    root = archive_root()
    slug = generate_slug(item)

    case ArchiveManager.move_to_archive(root, item.bootstrap_path, slug, Date.utc_today()) do
      {:ok, archive_path} ->
        {:ok, updated} =
          Items.update_item(item, %{
            status: "processing",
            archive_path: archive_path,
            slug: slug,
            bootstrap_path: nil
          })

        Logger.info("Item #{item.id} archived at #{archive_path}")

        # Re-evaluate for derived stages
        evaluate_and_enqueue(updated.id, state)

      {:error, reason} ->
        Logger.error("Failed to archive item #{item.id}: #{inspect(reason)}")
        Items.update_item(item, %{status: "failed", error_message: "Archive move failed: #{inspect(reason)}"})
    end
  end

  defp check_terminal_transition(item, state) do
    artifacts = Items.list_artifacts(item.id)
    exclusion_set = build_exclusion_set(item.id, artifacts)
    stages = Cham.Plugin.Registry.get_stages(state.registry)
    artifact_labels = Enum.map(artifacts, & &1.labels)

    ready_stages = DAG.find_next_stages(stages, artifact_labels, exclusion_set)

    # Check if any stages are still running
    active_count =
      Oban.Job
      |> where([j], j.worker == "Cham.Pipeline.StageWorker")
      |> where([j], j.state in ["available", "executing", "scheduled", "retryable"])
      |> where([j], fragment("args->>'item_id' = ?", ^item.id))
      |> Repo.aggregate(:count)

    if ready_stages == [] and active_count == 0 do
      # No more stages to run and none running
      failed_stages =
        Cham.JobTracking.StageExecution
        |> where([s], s.item_id == ^item.id and s.status == "failed")
        |> Repo.aggregate(:count)

      if failed_stages > 0 do
        Items.update_item(item, %{status: "incomplete"})
      else
        Items.update_item(item, %{status: "complete"})
      end
    end
  end

  defp produces_originals?(stage) do
    Enum.any?(stage.output_labels, fn labels ->
      Map.get(labels, "origin") == "original"
    end)
  end

  defp generate_slug(item) do
    title = item.title
    short_id = item.id |> String.slice(0, 6)

    if title && title != "" do
      slugify(title) <> "-" <> short_id
    else
      Logger.warning("Item #{item.id} has no title at archive time, using URL-derived slug")
      url_slug = slugify_url(item.url)
      url_slug <> "-" <> short_id
    end
  end

  defp slugify(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s-]/, "")
    |> String.replace(~r/[\s-]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 80)
  end

  defp slugify_url(url) do
    uri = URI.parse(url)
    path = (uri.host || "") <> (uri.path || "")
    slugify(path)
  end

  defp archive_root do
    Application.get_env(:cham, :archive_root, ".")
  end
end
```

- [ ] **Step 4: Run test to verify kick_off test passes**

Run: `mix test test/cham/pipeline/orchestrator_test.exs`
Expected: PASS

- [ ] **Step 5: Run full test suite**

Run: `mix format && mix test`
Expected: All tests pass

- [ ] **Step 6: Commit**

```bash
git add lib/cham/pipeline/orchestrator.ex test/cham/pipeline/orchestrator_test.exs
git commit -m "feat: add Pipeline.Orchestrator GenServer with kick_off and evaluate_and_enqueue"
```

---

## Task 5: Test stage_completed and stage_failed

**Files:**
- Modify: `test/cham/pipeline/orchestrator_test.exs`

- [ ] **Step 1: Write test for stage_completed enqueuing next stages**

Add to `test/cham/pipeline/orchestrator_test.exs`:

```elixir
  describe "stage_completed/3" do
    test "enqueues next ready stages after completion", %{orchestrator: orchestrator} do
      {:ok, item} =
        Items.create_item(%{
          url: "https://example.com/complete",
          slug: "complete-#{System.unique_integer([:positive])}",
          status: "bootstrapping"
        })

      # StageA requires origin:original,format:text and produces origin:derived,type:summary
      # StageB requires origin:original,format:audio and produces origin:derived,type:transcript
      # Create an artifact matching StageA's input AND StageA already completed
      {:ok, _} =
        Items.create_artifact(%{
          item_id: item.id,
          stage: "input",
          labels: %{"origin" => "original", "format" => "text"},
          filenames: [],
          path: "processing/input-20260404T000000Z",
          status: "produced"
        })

      {:ok, _} =
        Items.create_artifact(%{
          item_id: item.id,
          stage: "plugin_a",
          labels: %{"origin" => "derived", "type" => "summary"},
          filenames: ["summary.md"],
          path: "processing/plugin_a-20260404T000001Z",
          status: "produced"
        })

      # Now create an artifact matching StageB's input
      {:ok, _} =
        Items.create_artifact(%{
          item_id: item.id,
          stage: "some_stage",
          labels: %{"origin" => "original", "format" => "audio"},
          filenames: ["audio.mp3"],
          path: "processing/some_stage-20260404T000002Z",
          status: "produced"
        })

      Orchestrator.stage_completed(orchestrator, item.id, "some_stage")
      :sys.get_state(orchestrator)

      jobs = all_enqueued(worker: Cham.Pipeline.StageWorker)
      plugin_ids = Enum.map(jobs, & &1.args["plugin_id"])

      # StageB should be enqueued (audio input now available), StageA should not (already completed)
      assert "plugin_b" in plugin_ids
      refute "plugin_a" in plugin_ids
    end
  end
```

- [ ] **Step 2: Run test to verify it passes**

Run: `mix test test/cham/pipeline/orchestrator_test.exs`
Expected: PASS

- [ ] **Step 3: Write test for stage_failed with bootstrap failure**

Add to the test file:

```elixir
  describe "stage_failed/4" do
    test "marks item as failed when bootstrap stage fails", %{orchestrator: orchestrator} do
      {:ok, item} =
        Items.create_item(%{
          url: "https://example.com/fail",
          slug: "fail-#{System.unique_integer([:positive])}",
          status: "bootstrapping"
        })

      # Record a failed stage execution for a stage that produces originals
      Repo.insert!(%Cham.JobTracking.StageExecution{
        item_id: item.id,
        stage: "plugin_a",
        status: "failed",
        started_at: DateTime.utc_now(),
        ended_at: DateTime.utc_now(),
        error: "download failed"
      })

      Orchestrator.stage_failed(orchestrator, item.id, "plugin_a", "download failed")
      :sys.get_state(orchestrator)

      updated = Items.get_item!(item.id)
      assert updated.status == "failed"
    end
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/cham/pipeline/orchestrator_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add test/cham/pipeline/orchestrator_test.exs
git commit -m "test: add stage_completed and stage_failed orchestrator tests"
```

---

## Task 6: Test bootstrap → archive transition

**Files:**
- Modify: `test/cham/pipeline/orchestrator_test.exs`

- [ ] **Step 1: Write test for bootstrap to archive transition**

Add to the test file:

```elixir
  describe "bootstrap → archive transition" do
    test "moves item to archive when all originals complete", %{orchestrator: orchestrator} do
      tmp = Path.join(System.tmp_dir!(), "cham_orch_test_#{:erlang.unique_integer([:positive])}")
      bootstrap_path = Path.join(tmp, "tmp/bootstrap/test-item")
      processing_dir = Path.join(bootstrap_path, "processing")
      File.mkdir_p!(processing_dir)
      on_exit(fn -> File.rm_rf!(tmp) end)

      # Set archive_root for this test
      Application.put_env(:cham, :archive_root, tmp)
      on_exit(fn -> Application.delete_env(:cham, :archive_root) end)

      {:ok, item} =
        Items.create_item(%{
          url: "https://example.com/archive",
          slug: "archive-#{System.unique_integer([:positive])}",
          status: "bootstrapping",
          title: "Test Article Title"
        })

      {:ok, item} = Items.update_item(item, %{bootstrap_path: bootstrap_path})

      # Create artifacts for all original-producing stages
      # In our test registry: StageA outputs origin:derived (not original)
      # and EchoStage outputs origin:original — but we're using PluginA/PluginB
      # StageA: output_labels [%{"origin" => "derived", "type" => "summary"}] — NOT original
      # StageB: output_labels [%{"origin" => "derived", "type" => "transcript"}] — NOT original
      # Neither test plugin produces originals, so all_originals_complete? should be true
      # when there are no original-producing stages

      Orchestrator.stage_completed(orchestrator, item.id, "input")
      :sys.get_state(orchestrator)

      updated = Items.get_item!(item.id)
      assert updated.status == "processing"
      assert updated.archive_path != nil
      assert updated.slug =~ "test-article-title"
      assert updated.bootstrap_path == nil
    end
  end
```

- [ ] **Step 2: Run test to verify it passes**

Run: `mix test test/cham/pipeline/orchestrator_test.exs`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add test/cham/pipeline/orchestrator_test.exs
git commit -m "test: add bootstrap to archive transition test"
```

---

## Task 7: Test slug generation

**Files:**
- Modify: `test/cham/pipeline/orchestrator_test.exs`

- [ ] **Step 1: Write tests for slug generation**

Add to the test file:

```elixir
  describe "slug generation" do
    test "generates slug from title with short id suffix", %{orchestrator: orchestrator} do
      tmp = Path.join(System.tmp_dir!(), "cham_slug_test_#{:erlang.unique_integer([:positive])}")
      bootstrap_path = Path.join(tmp, "tmp/bootstrap/slug-item")
      File.mkdir_p!(Path.join(bootstrap_path, "processing"))
      on_exit(fn -> File.rm_rf!(tmp) end)

      Application.put_env(:cham, :archive_root, tmp)
      on_exit(fn -> Application.delete_env(:cham, :archive_root) end)

      {:ok, item} =
        Items.create_item(%{
          url: "https://example.com/slug",
          slug: "slug-#{System.unique_integer([:positive])}",
          status: "bootstrapping",
          title: "My Amazing Article — Special Edition!"
        })

      {:ok, _item} = Items.update_item(item, %{bootstrap_path: bootstrap_path})

      Orchestrator.stage_completed(orchestrator, item.id, "input")
      :sys.get_state(orchestrator)

      updated = Items.get_item!(item.id)
      # Slug should be lowercased, special chars removed, with ID suffix
      assert updated.slug =~ "my-amazing-article-special-edition"
      short_id = String.slice(item.id, 0, 6)
      assert String.ends_with?(updated.slug, short_id)
    end

    test "falls back to URL-derived slug when no title", %{orchestrator: orchestrator} do
      tmp = Path.join(System.tmp_dir!(), "cham_slug_url_test_#{:erlang.unique_integer([:positive])}")
      bootstrap_path = Path.join(tmp, "tmp/bootstrap/no-title-item")
      File.mkdir_p!(Path.join(bootstrap_path, "processing"))
      on_exit(fn -> File.rm_rf!(tmp) end)

      Application.put_env(:cham, :archive_root, tmp)
      on_exit(fn -> Application.delete_env(:cham, :archive_root) end)

      {:ok, item} =
        Items.create_item(%{
          url: "https://example.com/some/page",
          slug: "notitle-#{System.unique_integer([:positive])}",
          status: "bootstrapping"
        })

      {:ok, _item} = Items.update_item(item, %{bootstrap_path: bootstrap_path})

      Orchestrator.stage_completed(orchestrator, item.id, "input")
      :sys.get_state(orchestrator)

      updated = Items.get_item!(item.id)
      assert updated.slug =~ "example-com"
    end
  end
```

- [ ] **Step 2: Run test to verify it passes**

Run: `mix test test/cham/pipeline/orchestrator_test.exs`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add test/cham/pipeline/orchestrator_test.exs
git commit -m "test: add slug generation tests for title and URL fallback"
```

---

## Task 8: Test terminal states and recovery

**Files:**
- Modify: `test/cham/pipeline/orchestrator_test.exs`

- [ ] **Step 1: Write test for processing → complete transition**

Add to the test file:

```elixir
  describe "terminal transitions" do
    test "marks item complete when all stages done", %{orchestrator: orchestrator} do
      {:ok, item} =
        Items.create_item(%{
          url: "https://example.com/terminal",
          slug: "terminal-#{System.unique_integer([:positive])}",
          status: "processing",
          archive_path: "/tmp/fake/archive"
        })

      # All stages completed — plugin_a and plugin_b both produced artifacts
      {:ok, _} =
        Items.create_artifact(%{
          item_id: item.id,
          stage: "plugin_a",
          labels: %{"origin" => "derived", "type" => "summary"},
          filenames: ["summary.md"],
          path: "processing/plugin_a-20260404T000001Z",
          status: "produced"
        })

      {:ok, _} =
        Items.create_artifact(%{
          item_id: item.id,
          stage: "plugin_b",
          labels: %{"origin" => "derived", "type" => "transcript"},
          filenames: ["transcript.md"],
          path: "processing/plugin_b-20260404T000002Z",
          status: "produced"
        })

      Orchestrator.stage_completed(orchestrator, item.id, "plugin_b")
      :sys.get_state(orchestrator)

      updated = Items.get_item!(item.id)
      assert updated.status == "complete"
    end

    test "marks item incomplete when some stages failed", %{orchestrator: orchestrator} do
      {:ok, item} =
        Items.create_item(%{
          url: "https://example.com/incomplete",
          slug: "incomplete-#{System.unique_integer([:positive])}",
          status: "processing",
          archive_path: "/tmp/fake/archive"
        })

      # plugin_a completed, plugin_b failed
      {:ok, _} =
        Items.create_artifact(%{
          item_id: item.id,
          stage: "plugin_a",
          labels: %{"origin" => "derived", "type" => "summary"},
          filenames: ["summary.md"],
          path: "processing/plugin_a-20260404T000001Z",
          status: "produced"
        })

      Repo.insert!(%Cham.JobTracking.StageExecution{
        item_id: item.id,
        stage: "plugin_b",
        status: "failed",
        started_at: DateTime.utc_now(),
        ended_at: DateTime.utc_now(),
        error: "transcription failed"
      })

      Orchestrator.stage_failed(orchestrator, item.id, "plugin_b", "transcription failed")
      :sys.get_state(orchestrator)

      updated = Items.get_item!(item.id)
      assert updated.status == "incomplete"
    end
  end
```

- [ ] **Step 2: Run test to verify it passes**

Run: `mix test test/cham/pipeline/orchestrator_test.exs`
Expected: PASS

- [ ] **Step 3: Write test for periodic recovery**

Add to the test file:

```elixir
  describe "recovery" do
    test "recovers stalled items on startup", %{registry: registry} do
      {:ok, item} =
        Items.create_item(%{
          url: "https://example.com/stalled",
          slug: "stalled-#{System.unique_integer([:positive])}",
          status: "bootstrapping"
        })

      # Item has input artifact matching StageA but no Oban job
      {:ok, _} =
        Items.create_artifact(%{
          item_id: item.id,
          stage: "input",
          labels: %{"origin" => "original", "format" => "text"},
          filenames: [],
          path: "processing/input-20260404T000000Z",
          status: "produced"
        })

      # Start a new Orchestrator — should recover the stalled item
      recovery_name = :"recovery_orch_#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        Orchestrator.start_link(
          name: recovery_name,
          registry: registry,
          recovery_interval: :infinity
        )

      # Wait for {:continue, :recover} to process
      :sys.get_state(recovery_name)

      jobs = all_enqueued(worker: Cham.Pipeline.StageWorker)
      item_jobs = Enum.filter(jobs, &(&1.args["item_id"] == item.id))
      assert length(item_jobs) > 0
    end
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/cham/pipeline/orchestrator_test.exs`
Expected: PASS

- [ ] **Step 5: Run full test suite**

Run: `mix format && mix test`
Expected: All tests pass

- [ ] **Step 6: Commit**

```bash
git add test/cham/pipeline/orchestrator_test.exs
git commit -m "test: add terminal state and recovery tests for Orchestrator"
```

---

## Task 9: Wire up submit_url and Application

**Files:**
- Modify: `lib/cham/pipeline.ex`
- Modify: `lib/cham/application.ex`

- [ ] **Step 1: Add Orchestrator.kick_off to Pipeline.submit_url**

In `lib/cham/pipeline.ex`, update the `submit_url/2` function:

```elixir
  def submit_url(url, opts \\ []) do
    root = Keyword.get(opts, :root, ".")
    tags = Keyword.get(opts, :tags, [])

    with {:ok, item} <- Items.create_item(%{url: url, tags: tags}),
         {:ok, item} <- setup_bootstrap(item, root),
         {:ok, _artifact} <- create_input_artifact(item, url) do
      Cham.Pipeline.Orchestrator.kick_off(item.id)
      {:ok, item}
    end
  end
```

- [ ] **Step 2: Add Orchestrator to supervision tree**

In `lib/cham/application.ex`, add the Orchestrator after the Plugin.Registry and before the tracker:

```elixir
    children =
      [
        ChamWeb.Telemetry,
        Cham.Repo,
        {Oban, Application.fetch_env!(:cham, Oban)},
        {DNSCluster, query: Application.get_env(:cham, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Cham.PubSub},
        {Cham.Config.Manager,
         toml_path: Application.get_env(:cham, :config_toml_path, "config/cham.toml"),
         event_bus: Cham.PubSub},
        {Cham.Plugin.Registry, name: Cham.Plugin.Registry, plugin_order: []},
        Cham.Pipeline.Orchestrator
      ] ++
        tracker_children() ++
        [
          ChamWeb.Endpoint
        ]
```

- [ ] **Step 3: Run full test suite**

Run: `mix format && mix test`
Expected: All tests pass

- [ ] **Step 4: Commit**

```bash
git add lib/cham/pipeline.ex lib/cham/application.ex
git commit -m "feat: wire Orchestrator into submit_url and application supervision tree"
```

---

## Task 10: Final verification

- [ ] **Step 1: Run full test suite**

Run: `mix test`
Expected: All tests pass

- [ ] **Step 2: Check formatting**

Run: `mix format --check-formatted`
Expected: No formatting issues

- [ ] **Step 3: Check compilation**

Run: `mix compile --warnings-as-errors`
Expected: Clean compilation

- [ ] **Step 4: Verify dev server starts**

Run: `mix phx.server`
Expected: Server starts without errors, Orchestrator is in the supervision tree, core plugins registered

- [ ] **Step 5: Smoke test in iex** (optional)

```elixir
# In iex -S mix
Cham.Pipeline.submit_url("https://example.com")
# Observe: item created, Oban job enqueued for generic_download_url
```
