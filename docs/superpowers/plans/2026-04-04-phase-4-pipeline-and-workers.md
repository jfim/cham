# Phase 4: Processing Pipeline & Workers — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the processing pipeline core — label matching, DAG construction, the Oban StageWorker that dispatches to stage modules and drives item state transitions, the pipeline entry point (submit URL), and Job Tracking for stage execution history and ephemeral progress.

**Architecture:** Label matching is a pure function used by the DAG builder. The DAG builder finds which stages can run given available artifacts and desired outputs. The StageWorker is a single Oban worker that dispatches to all stage modules, writes artifact.json, publishes events, and enqueues next stages. The Pipeline module provides the submit_url entry point. Job Tracking subscribes to pipeline events via the Event Bus and records stage execution history in the database.

**Tech Stack:** Oban 2.18+, Ecto, Phoenix.PubSub (via EventBus)

---

## File Structure

### New Files

| File | Responsibility |
|------|---------------|
| `lib/cham/pipeline/events.ex` | Pipeline event structs (StageStarted, StageCompleted, etc.) |
| `lib/cham/pipeline/label_matcher.ex` | Pure function: does an artifact match a stage's input matchers? |
| `lib/cham/pipeline/dag.ex` | DAG builder: find ready stages given available artifacts |
| `lib/cham/pipeline/stage_worker.ex` | Oban worker: dispatch to stages, write artifact.json, re-evaluate DAG |
| `lib/cham/pipeline.ex` | Entry point: submit_url, handles item lifecycle |
| `lib/cham/job_tracking/tracker.ex` | GenServer: subscribes to events, records history, holds ephemeral progress |
| `test/cham/pipeline/label_matcher_test.exs` | Label matching tests |
| `test/cham/pipeline/dag_test.exs` | DAG builder tests |
| `test/cham/pipeline/stage_worker_test.exs` | StageWorker tests with mock stages |
| `test/cham/pipeline_test.exs` | Integration test for submit_url flow |
| `test/cham/job_tracking/tracker_test.exs` | Job Tracking tests |

### Parallelism

```
Task 1 (events) ──┬── Task 2 (label matcher) → Task 3 (DAG) → Task 4 (StageWorker) → Task 5 (Pipeline)
                   └── Task 6 (Job Tracking) [independent]
```

Tasks 1+6 can be done first in parallel. Then 2, then 3, then 4+5.

---

## Task 1: Pipeline Events

Event structs published by the StageWorker and consumed by Job Tracking and the Web UI.

**Files:**
- Create: `lib/cham/pipeline/events.ex`

- [ ] **Step 1: Create event structs**

Create `lib/cham/pipeline/events.ex`:

```elixir
defmodule Cham.Pipeline.Events do
  defmodule StageStarted do
    @enforce_keys [:stage_id, :item_id]
    defstruct [:stage_id, :item_id, :attempt]
  end

  defmodule StageCompleted do
    @enforce_keys [:stage_id, :item_id]
    defstruct [:stage_id, :item_id, :duration_ms, metadata: %{}]
  end

  defmodule StageFailed do
    @enforce_keys [:stage_id, :item_id, :error]
    defstruct [:stage_id, :item_id, :error, :attempt]
  end

  defmodule StageSnoozed do
    @enforce_keys [:stage_id, :item_id, :duration_ms, :reason]
    defstruct [:stage_id, :item_id, :duration_ms, :reason]
  end

  defmodule StageProgress do
    @enforce_keys [:stage_id, :item_id]
    defstruct [:stage_id, :item_id, :progress, :message]
  end

  defmodule PipelineComplete do
    @enforce_keys [:item_id, :status]
    defstruct [:item_id, :status]
  end
end
```

- [ ] **Step 2: Commit**

```bash
git add lib/cham/pipeline/events.ex
git commit -m "feat: add pipeline event structs

StageStarted, StageCompleted, StageFailed, StageSnoozed,
StageProgress, PipelineComplete. Published by StageWorker,
consumed by Job Tracking and Web UI."
```

---

## Task 2: Label Matcher

Pure function that checks whether an artifact's labels satisfy a stage's input matchers. Supports negation (`!key` or `!value`).

**Files:**
- Create: `lib/cham/pipeline/label_matcher.ex`
- Create: `test/cham/pipeline/label_matcher_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/cham/pipeline/label_matcher_test.exs`:

```elixir
defmodule Cham.Pipeline.LabelMatcherTest do
  use ExUnit.Case, async: true

  alias Cham.Pipeline.LabelMatcher

  describe "matches?/2" do
    test "matches when artifact has all required labels" do
      artifact_labels = %{"origin" => "original", "format" => "text", "type" => "article"}
      matcher = %{"origin" => "original", "format" => "text"}
      assert LabelMatcher.matches?(artifact_labels, matcher)
    end

    test "matches when artifact has extra labels beyond matcher" do
      artifact_labels = %{"origin" => "original", "format" => "text", "extra" => "value"}
      matcher = %{"origin" => "original"}
      assert LabelMatcher.matches?(artifact_labels, matcher)
    end

    test "does not match when a required label is missing" do
      artifact_labels = %{"origin" => "original"}
      matcher = %{"origin" => "original", "format" => "text"}
      refute LabelMatcher.matches?(artifact_labels, matcher)
    end

    test "does not match when label value differs" do
      artifact_labels = %{"origin" => "derived", "format" => "text"}
      matcher = %{"origin" => "original", "format" => "text"}
      refute LabelMatcher.matches?(artifact_labels, matcher)
    end

    test "empty matcher matches any artifact" do
      artifact_labels = %{"origin" => "original", "format" => "video"}
      assert LabelMatcher.matches?(artifact_labels, %{})
    end

    test "negation: !value means label must not have that value" do
      artifact_labels = %{"format" => "video", "codec" => "h264"}
      matcher = %{"format" => "video", "codec" => "!webm"}
      assert LabelMatcher.matches?(artifact_labels, matcher)
    end

    test "negation: fails when label has the negated value" do
      artifact_labels = %{"format" => "video", "codec" => "webm"}
      matcher = %{"format" => "video", "codec" => "!webm"}
      refute LabelMatcher.matches?(artifact_labels, matcher)
    end

    test "negation: !value matches when label is absent" do
      artifact_labels = %{"format" => "video"}
      matcher = %{"format" => "video", "codec" => "!webm"}
      assert LabelMatcher.matches?(artifact_labels, matcher)
    end
  end

  describe "find_matching_artifacts/2" do
    test "returns artifacts that match any of the matchers" do
      artifacts = [
        %{labels: %{"origin" => "original", "format" => "text"}},
        %{labels: %{"origin" => "original", "format" => "video"}},
        %{labels: %{"origin" => "derived", "type" => "summary"}}
      ]

      matchers = [%{"origin" => "original", "format" => "text"}]
      matched = LabelMatcher.find_matching_artifacts(artifacts, matchers)
      assert length(matched) == 1
      assert hd(matched).labels["format"] == "text"
    end

    test "returns all artifacts matching any matcher in the list" do
      artifacts = [
        %{labels: %{"origin" => "original", "format" => "text"}},
        %{labels: %{"origin" => "original", "format" => "video"}},
        %{labels: %{"origin" => "derived", "type" => "summary"}}
      ]

      matchers = [
        %{"origin" => "original", "format" => "text"},
        %{"origin" => "original", "format" => "video"}
      ]

      matched = LabelMatcher.find_matching_artifacts(artifacts, matchers)
      assert length(matched) == 2
    end

    test "returns empty list when nothing matches" do
      artifacts = [%{labels: %{"origin" => "derived"}}]
      matchers = [%{"origin" => "original"}]
      assert LabelMatcher.find_matching_artifacts(artifacts, matchers) == []
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
mix test test/cham/pipeline/label_matcher_test.exs
```

- [ ] **Step 3: Implement the Label Matcher**

Create `lib/cham/pipeline/label_matcher.ex`:

```elixir
defmodule Cham.Pipeline.LabelMatcher do
  @doc """
  Check if an artifact's labels satisfy a matcher.
  A matcher is a map of required label key-value pairs.
  Values starting with "!" are negations: the artifact must NOT have that value.
  Missing labels in the artifact satisfy negation matchers.
  An empty matcher matches any artifact.
  """
  def matches?(artifact_labels, matcher) do
    Enum.all?(matcher, fn {key, pattern} ->
      match_label(artifact_labels, key, pattern)
    end)
  end

  @doc """
  Find all artifacts whose labels match any of the given matchers.
  Each matcher in the list is an alternative (OR). Within a matcher, all
  key-value pairs must match (AND).
  """
  def find_matching_artifacts(artifacts, matchers) do
    Enum.filter(artifacts, fn artifact ->
      Enum.any?(matchers, fn matcher ->
        matches?(artifact.labels, matcher)
      end)
    end)
  end

  defp match_label(artifact_labels, key, "!" <> negated_value) do
    case Map.get(artifact_labels, key) do
      nil -> true
      value -> value != negated_value
    end
  end

  defp match_label(artifact_labels, key, expected_value) do
    Map.get(artifact_labels, key) == expected_value
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
mix test test/cham/pipeline/label_matcher_test.exs
```

Expected: all 11 tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/cham/pipeline/label_matcher.ex test/cham/pipeline/label_matcher_test.exs
git commit -m "feat: add label matcher for artifact-to-stage matching

Pure function that checks if an artifact's labels satisfy a stage's
input matchers. Supports negation (!value). Used by DAG builder to
wire stages into the processing graph."
```

---

## Task 3: DAG Builder

Given a list of registered stages and currently available artifacts, determines which stages are ready to run (their inputs are satisfied) and which are pending (inputs not yet available but could be produced by other stages).

**Files:**
- Create: `lib/cham/pipeline/dag.ex`
- Create: `test/cham/pipeline/dag_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/cham/pipeline/dag_test.exs`:

```elixir
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
        stage("summarize", [%{"origin" => "original", "format" => "text"}], [%{"origin" => "derived", "type" => "summary"}]),
        stage("transcribe", [%{"origin" => "original", "format" => "audio"}], [%{"origin" => "derived", "type" => "transcript"}])
      ]

      available_artifacts = [
        %{labels: %{"origin" => "original", "format" => "text"}, filenames: ["article.html"], path: "processing/dl-123"}
      ]

      ready = DAG.find_ready_stages(stages, available_artifacts)
      assert length(ready) == 1
      assert hd(ready).plugin_id == "summarize"
    end

    test "returns empty list when no stages have satisfied inputs" do
      stages = [
        stage("summarize", [%{"origin" => "original", "format" => "text"}], [%{"origin" => "derived", "type" => "summary"}])
      ]

      available_artifacts = [
        %{labels: %{"origin" => "original", "format" => "video"}, filenames: [], path: "p/v"}
      ]

      assert DAG.find_ready_stages(stages, available_artifacts) == []
    end

    test "returns multiple stages when multiple are ready" do
      stages = [
        stage("summarize", [%{"origin" => "original", "format" => "text"}], [%{"origin" => "derived", "type" => "summary"}]),
        stage("tag", [%{"origin" => "original", "format" => "text"}], [%{"origin" => "derived", "type" => "tags"}])
      ]

      available_artifacts = [
        %{labels: %{"origin" => "original", "format" => "text"}, filenames: ["a.html"], path: "p/d"}
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
        stage("summarize", [%{"origin" => "original", "format" => "text"}], [%{"origin" => "derived", "type" => "summary"}])
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
        stage("summarize", [%{"origin" => "original", "format" => "text"}], [%{"origin" => "derived", "type" => "summary"}])
      ]

      available_artifacts = [
        %{labels: %{"domain" => "example.com"}, filenames: [], path: "p/input"},
        %{labels: %{"origin" => "original", "format" => "text"}, filenames: ["a.html"], path: "p/dl"}
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
        stage("summarize", [%{"format" => "text"}], [%{"origin" => "derived", "type" => "summary"}])
      ]

      completed = MapSet.new(["summarize"])
      assert DAG.all_originals_complete?(stages, completed)
    end

    test "returns true when all original-producing stages are completed" do
      stages = [
        stage("download", [%{}], [%{"origin" => "original", "format" => "text"}]),
        stage("summarize", [%{"format" => "text"}], [%{"origin" => "derived", "type" => "summary"}])
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
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
mix test test/cham/pipeline/dag_test.exs
```

- [ ] **Step 3: Implement the DAG builder**

Create `lib/cham/pipeline/dag.ex`:

```elixir
defmodule Cham.Pipeline.DAG do
  alias Cham.Pipeline.LabelMatcher

  @doc """
  Find stages whose input matchers are satisfied by the available artifacts.
  A stage is ready when at least one artifact matches each of its input matchers.
  """
  def find_ready_stages(stages, available_artifacts) do
    Enum.filter(stages, fn stage ->
      stage.input_matchers != [] and
        Enum.all?(stage.input_matchers, fn matcher ->
          Enum.any?(available_artifacts, fn artifact ->
            LabelMatcher.matches?(artifact.labels, matcher)
          end)
        end)
    end)
  end

  @doc """
  Remove stages that have already been run (by plugin_id).
  """
  def exclude_already_run(stages, completed_stage_ids) do
    Enum.reject(stages, fn stage ->
      MapSet.member?(completed_stage_ids, stage.plugin_id)
    end)
  end

  @doc """
  Find the next stages to enqueue: stages that are ready and haven't run yet.
  """
  def find_next_stages(stages, available_artifacts, completed_stage_ids) do
    stages
    |> exclude_already_run(completed_stage_ids)
    |> find_ready_stages(available_artifacts)
  end

  @doc """
  Check if all stages that produce `origin:original` artifacts have completed.
  This determines the archive threshold — when the item moves from bootstrap to archive.
  """
  def all_originals_complete?(stages, completed_stage_ids) do
    stages
    |> Enum.filter(&produces_originals?/1)
    |> Enum.all?(fn stage -> MapSet.member?(completed_stage_ids, stage.plugin_id) end)
  end

  defp produces_originals?(stage) do
    Enum.any?(stage.output_labels, fn labels ->
      Map.get(labels, "origin") == "original"
    end)
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
mix test test/cham/pipeline/dag_test.exs
```

Expected: all 7 tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/cham/pipeline/dag.ex test/cham/pipeline/dag_test.exs
git commit -m "feat: add DAG builder for stage scheduling

Pure functions to find ready stages (inputs satisfied), exclude
already-run stages, and check archive threshold (all originals
complete). Used by StageWorker for pipeline progression."
```

---

## Task 4: StageWorker (Oban)

The single Oban worker that dispatches to stage modules. On success, it writes artifact.json, records artifacts in the database, publishes events, and enqueues next stages.

**Files:**
- Create: `lib/cham/pipeline/stage_worker.ex`
- Create: `test/cham/pipeline/stage_worker_test.exs`
- Modify: `test/support/test_plugins.ex` (add a stage that produces files)

- [ ] **Step 1: Add a test stage that actually produces output**

Add to `test/support/test_plugins.ex`:

```elixir
defmodule Cham.TestPlugins.EchoStage do
  @behaviour Cham.Stage

  @impl true
  def name, do: "Echo Stage"
  @impl true
  def description, do: "Test stage that echoes input to output"
  @impl true
  def input_matchers, do: [%{"domain" => "example.com"}]
  @impl true
  def output_labels, do: [%{"origin" => "original", "format" => "text"}]
  @impl true
  def queue, do: :general
  @impl true
  def max_attempts, do: 3

  @impl true
  def perform(_inputs, working_dir, _desired, _item_id) do
    File.write!(Path.join(working_dir, "output.txt"), "echo output")

    {:ok,
     %{
       artifacts: [%{labels: %{"origin" => "original", "format" => "text"}, filenames: ["output.txt"]}],
       item_metadata: %{"title" => "Test Item", "content_type" => "article"},
       provenance: %{"plugin_version" => "0.1.0"}
     }}
  end
end
```

- [ ] **Step 2: Write the failing tests**

Create `test/cham/pipeline/stage_worker_test.exs`:

```elixir
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
    test "runs a stage, writes artifact.json, and records artifacts in DB", %{item: item, tmp: tmp} do
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
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
mix test test/cham/pipeline/stage_worker_test.exs
```

- [ ] **Step 4: Implement the StageWorker**

Create `lib/cham/pipeline/stage_worker.ex`:

```elixir
defmodule Cham.Pipeline.StageWorker do
  use Oban.Worker, max_attempts: 3

  alias Cham.Archive.{ArchiveManager, FilesystemManager}
  alias Cham.Items
  alias Cham.Pipeline.Events.{StageStarted, StageCompleted, StageFailed, StageSnoozed}

  require Logger

  @doc """
  Oban perform callback. Job args: %{"item_id" => id, "stage_module" => module_string, "plugin_id" => id}
  """
  @impl Oban.Worker
  def perform(%Oban.Job{args: args, attempt: attempt}) do
    item_id = args["item_id"]
    stage_module = String.to_existing_atom(args["stage_module"])
    plugin_id = args["plugin_id"]

    item = Items.get_item!(item_id)
    item_dir = resolve_item_dir(item)

    case execute_stage(stage_module, plugin_id, item, item_dir) do
      {:ok, _stage_dir} ->
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

  @doc """
  Execute a stage for an item. Creates working directory, calls stage.perform,
  writes artifact.json, records artifacts in DB, publishes events.
  Returns {:ok, stage_dir} | {:error, reason} | {:snooze, ms, reason}.
  """
  def execute_stage(stage_module, plugin_id, item, item_dir) do
    start_time = System.monotonic_time(:millisecond)
    start_ts = DateTime.utc_now() |> DateTime.to_unix()

    # Publish start event
    Cham.EventBus.publish("pipeline:stage_started", %StageStarted{
      stage_id: plugin_id,
      item_id: item.id
    })

    # Create working directory
    {:ok, stage_dir} = ArchiveManager.create_stage_dir(item_dir, plugin_id)

    # Resolve input artifacts
    input_artifacts = resolve_inputs(stage_module, item.id)

    # Execute the stage
    case stage_module.perform(input_artifacts, stage_dir, [], item.id) do
      {:ok, result} ->
        end_ts = DateTime.utc_now() |> DateTime.to_unix()
        duration_ms = System.monotonic_time(:millisecond) - start_time

        # Write artifact.json
        write_artifact_json(stage_dir, plugin_id, start_ts, end_ts, result)

        # Record artifacts in DB
        record_artifacts(item.id, plugin_id, stage_dir, result)

        # Update item metadata
        update_item_metadata(item, result)

        # Publish completion event
        Cham.EventBus.publish("pipeline:stage_completed", %StageCompleted{
          stage_id: plugin_id,
          item_id: item.id,
          duration_ms: duration_ms,
          metadata: result[:item_metadata] || %{}
        })

        {:ok, stage_dir}

      {:error, reason} ->
        Cham.EventBus.publish("pipeline:stage_failed", %StageFailed{
          stage_id: plugin_id,
          item_id: item.id,
          error: inspect(reason)
        })

        {:error, reason}

      {:snooze, duration_ms, reason} ->
        {:snooze, duration_ms, reason}
    end
  end

  defp resolve_item_dir(item) do
    cond do
      item.archive_path -> item.archive_path
      item.bootstrap_path -> item.bootstrap_path
      true -> raise "Item #{item.id} has no archive_path or bootstrap_path"
    end
  end

  defp resolve_inputs(stage_module, item_id) do
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
            input_path: a.path
          }
        end)
      end)
    else
      []
    end
  end

  defp write_artifact_json(stage_dir, plugin_id, start_ts, end_ts, result) do
    data = %{
      "stage" => %{
        "plugin_id" => plugin_id,
        "start_ts" => start_ts,
        "end_ts" => end_ts
      },
      "artifacts" =>
        Enum.map(result[:artifacts] || [], fn a ->
          %{
            "labels" => stringify_keys(a.labels),
            "filenames" => a.filenames
          }
        end),
      "item_metadata" => stringify_keys(result[:item_metadata] || %{}),
      "provenance" => stringify_keys(result[:provenance] || %{})
    }

    json = Jason.encode!(data, pretty: true)
    FilesystemManager.atomic_write(Path.join(stage_dir, "artifact.json"), json)
  end

  defp record_artifacts(item_id, plugin_id, stage_dir, result) do
    now = DateTime.utc_now()
    relative_path = "processing/#{Path.basename(stage_dir)}"

    Enum.each(result[:artifacts] || [], fn artifact ->
      Items.create_artifact(%{
        item_id: item_id,
        stage: plugin_id,
        labels: stringify_keys(artifact.labels),
        filenames: artifact.filenames,
        path: relative_path,
        status: "produced",
        started_at: now,
        ended_at: now
      })
    end)
  end

  defp update_item_metadata(item, result) do
    meta = result[:item_metadata] || %{}

    updates =
      %{}
      |> maybe_put(:title, meta[:title] || meta["title"])
      |> maybe_put(:content_type, meta[:content_type] || meta["content_type"])

    if updates != %{} do
      Items.update_item(item, updates)
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
mix test test/cham/pipeline/stage_worker_test.exs
```

Expected: test passes.

- [ ] **Step 6: Run all tests**

```bash
mix test
```

Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add lib/cham/pipeline/stage_worker.ex test/cham/pipeline/stage_worker_test.exs test/support/test_plugins.ex
git commit -m "feat: add StageWorker for Oban-based stage execution

Single Oban worker that dispatches to stage modules. Creates working
directory, calls stage.perform, writes artifact.json, records artifacts
in DB, publishes events. Handles ok/error/snooze results."
```

---

## Task 5: Pipeline Entry Point

The `Cham.Pipeline` module provides `submit_url/1` — the main entry point for processing a URL. Creates an item, creates the input artifact, sets up the bootstrap directory, and enqueues initial stages.

**Files:**
- Create: `lib/cham/pipeline.ex`
- Create: `test/cham/pipeline_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/cham/pipeline_test.exs`:

```elixir
defmodule Cham.PipelineTest do
  use Cham.DataCase

  alias Cham.Pipeline
  alias Cham.Items

  setup do
    tmp = Path.join(System.tmp_dir!(), "cham_pipeline_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    %{root: tmp}
  end

  describe "submit_url/2" do
    test "creates item in bootstrapping status", %{root: root} do
      assert {:ok, item} = Pipeline.submit_url("https://example.com/article", root: root)
      assert item.status == "bootstrapping"
      assert item.url == "https://example.com/article"
    end

    test "creates input artifact with domain label", %{root: root} do
      {:ok, item} = Pipeline.submit_url("https://example.com/article", root: root)
      [artifact] = Items.list_artifacts(item.id)
      assert artifact.stage == "input"
      assert artifact.labels["domain"] == "example.com"
    end

    test "creates bootstrap directory", %{root: root} do
      {:ok, item} = Pipeline.submit_url("https://example.com/article", root: root)
      assert item.bootstrap_path != nil
      assert File.dir?(item.bootstrap_path)
    end

    test "writes input artifact.json to bootstrap directory", %{root: root} do
      {:ok, item} = Pipeline.submit_url("https://example.com/article", root: root)
      # Check that processing/input-*/artifact.json exists
      stage_dirs = Cham.Archive.ArchiveManager.list_stage_dirs(item.bootstrap_path)
      assert length(stage_dirs) == 1
      assert Path.basename(hd(stage_dirs)) =~ "input-"
    end

    test "rejects duplicate URL", %{root: root} do
      {:ok, _} = Pipeline.submit_url("https://example.com/dup", root: root)
      assert {:error, changeset} = Pipeline.submit_url("https://example.com/dup", root: root)
      assert errors_on(changeset).url != nil
    end

    test "extracts domain from various URL formats", %{root: root} do
      {:ok, item} = Pipeline.submit_url("https://www.nebula.tv/videos/test", root: root)
      [artifact] = Items.list_artifacts(item.id)
      assert artifact.labels["domain"] == "www.nebula.tv"
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
mix test test/cham/pipeline_test.exs
```

- [ ] **Step 3: Implement the Pipeline module**

Create `lib/cham/pipeline.ex`:

```elixir
defmodule Cham.Pipeline do
  alias Cham.Items
  alias Cham.Archive.{ArchiveManager, FilesystemManager}

  @doc """
  Submit a URL for processing. Creates an item, input artifact,
  and bootstrap directory. Returns {:ok, item} or {:error, changeset}.

  Options:
  - root: archive root directory (default: ".")
  - tags: list of user-supplied tags
  """
  def submit_url(url, opts \\ []) do
    root = Keyword.get(opts, :root, ".")
    tags = Keyword.get(opts, :tags, [])

    with {:ok, item} <- Items.create_item(%{url: url, tags: tags}),
         {:ok, item} <- setup_bootstrap(item, root),
         {:ok, _artifact} <- create_input_artifact(item, url) do
      {:ok, item}
    end
  end

  defp setup_bootstrap(item, root) do
    bootstrap_path = ArchiveManager.bootstrap_path(root, item.id)
    FilesystemManager.mkdir_p(bootstrap_path)
    Items.update_item(item, %{bootstrap_path: bootstrap_path})
  end

  defp create_input_artifact(item, url) do
    domain = extract_domain(url)
    start_ts = DateTime.utc_now() |> DateTime.to_unix()

    # Create the input stage directory
    {:ok, stage_dir} = ArchiveManager.create_stage_dir(item.bootstrap_path, "input")

    # Write artifact.json
    data = %{
      "stage" => %{"plugin_id" => "input", "start_ts" => start_ts, "end_ts" => start_ts},
      "artifacts" => [%{"labels" => %{"domain" => domain}, "filenames" => []}],
      "item_metadata" => %{"url" => url}
    }

    FilesystemManager.atomic_write(
      Path.join(stage_dir, "artifact.json"),
      Jason.encode!(data, pretty: true)
    )

    # Record in DB
    relative_path = "processing/#{Path.basename(stage_dir)}"

    Items.create_artifact(%{
      item_id: item.id,
      stage: "input",
      labels: %{"domain" => domain},
      filenames: [],
      path: relative_path,
      status: "produced"
    })
  end

  defp extract_domain(url) do
    uri = URI.parse(url)
    uri.host || "unknown"
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
mix test test/cham/pipeline_test.exs
```

Expected: all 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/cham/pipeline.ex test/cham/pipeline_test.exs
git commit -m "feat: add Pipeline.submit_url entry point

Creates item, input artifact with domain label, bootstrap directory,
and writes input artifact.json. Extracts domain from URL for
stage matching. Entry point for the processing pipeline."
```

---

## Task 6: Job Tracking

GenServer that subscribes to pipeline events via the Event Bus and records stage execution history in the database. Also holds ephemeral intra-stage progress in memory.

**Files:**
- Create: `lib/cham/job_tracking/tracker.ex`
- Create: `test/cham/job_tracking/tracker_test.exs`
- Modify: `lib/cham/application.ex` (add Tracker to supervision tree)

- [ ] **Step 1: Write the failing tests**

Create `test/cham/job_tracking/tracker_test.exs`:

```elixir
defmodule Cham.JobTracking.TrackerTest do
  use Cham.DataCase

  alias Cham.JobTracking.Tracker
  alias Cham.Pipeline.Events.{StageStarted, StageCompleted, StageFailed, StageSnoozed, StageProgress}
  alias Cham.Items

  setup do
    name = :"tracker_#{:erlang.unique_integer([:positive])}"
    start_supervised!({Tracker, name: name})
    {:ok, item} = Items.create_item(%{url: "https://example.com/track-#{:erlang.unique_integer([:positive])}"})
    %{tracker: name, item: item}
  end

  describe "stage execution recording" do
    test "records StageStarted event", %{item: item} do
      Cham.EventBus.publish("pipeline:stage_started", %StageStarted{
        stage_id: "transcribe",
        item_id: item.id,
        attempt: 1
      })

      # Give the GenServer time to process
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
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
mix test test/cham/job_tracking/tracker_test.exs
```

- [ ] **Step 3: Implement the Tracker**

Create `lib/cham/job_tracking/tracker.ex`:

```elixir
defmodule Cham.JobTracking.Tracker do
  use GenServer

  alias Cham.Repo
  alias Cham.JobTracking.StageExecution
  alias Cham.Pipeline.Events.{StageStarted, StageCompleted, StageFailed, StageSnoozed, StageProgress}

  import Ecto.Query

  # --- Client API ---

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def get_stage_history(item_id) do
    StageExecution
    |> where([s], s.item_id == ^item_id)
    |> order_by([s], asc: s.started_at)
    |> Repo.all()
  end

  def get_progress(server \\ __MODULE__, item_id) do
    GenServer.call(server, {:get_progress, item_id})
  end

  # --- Server ---

  @impl true
  def init(_opts) do
    Cham.EventBus.subscribe("pipeline")
    {:ok, %{progress: %{}}}
  end

  @impl true
  def handle_info(%StageStarted{} = event, state) do
    now = DateTime.utc_now()

    %StageExecution{}
    |> StageExecution.changeset(%{
      item_id: event.item_id,
      stage: event.stage_id,
      status: "started",
      attempt: event.attempt || 1,
      started_at: now
    })
    |> Repo.insert!()

    {:noreply, state}
  end

  def handle_info(%StageCompleted{} = event, state) do
    now = DateTime.utc_now()

    StageExecution
    |> where([s], s.item_id == ^event.item_id and s.stage == ^event.stage_id and s.status == "started")
    |> order_by([s], desc: s.started_at)
    |> limit(1)
    |> Repo.one()
    |> case do
      nil -> :ok
      execution ->
        execution
        |> StageExecution.changeset(%{
          status: "completed",
          ended_at: now,
          duration_ms: event.duration_ms
        })
        |> Repo.update!()
    end

    # Clear progress for this stage
    new_progress = clear_stage_progress(state.progress, event.item_id, event.stage_id)
    {:noreply, %{state | progress: new_progress}}
  end

  def handle_info(%StageFailed{} = event, state) do
    now = DateTime.utc_now()

    StageExecution
    |> where([s], s.item_id == ^event.item_id and s.stage == ^event.stage_id and s.status == "started")
    |> order_by([s], desc: s.started_at)
    |> limit(1)
    |> Repo.one()
    |> case do
      nil -> :ok
      execution ->
        execution
        |> StageExecution.changeset(%{
          status: "failed",
          ended_at: now,
          error: event.error
        })
        |> Repo.update!()
    end

    new_progress = clear_stage_progress(state.progress, event.item_id, event.stage_id)
    {:noreply, %{state | progress: new_progress}}
  end

  def handle_info(%StageSnoozed{} = event, state) do
    now = DateTime.utc_now()

    StageExecution
    |> where([s], s.item_id == ^event.item_id and s.stage == ^event.stage_id and s.status == "started")
    |> order_by([s], desc: s.started_at)
    |> limit(1)
    |> Repo.one()
    |> case do
      nil -> :ok
      execution ->
        execution
        |> StageExecution.changeset(%{
          status: "snoozed",
          ended_at: now,
          snooze_reason: event.reason
        })
        |> Repo.update!()
    end

    {:noreply, state}
  end

  def handle_info(%StageProgress{} = event, state) do
    new_progress =
      state.progress
      |> Map.put_new(event.item_id, %{})
      |> put_in([event.item_id, event.stage_id], %{
        progress: event.progress,
        message: event.message
      })

    {:noreply, %{state | progress: new_progress}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call({:get_progress, item_id}, _from, state) do
    progress = Map.get(state.progress, item_id, %{})
    {:reply, progress, state}
  end

  defp clear_stage_progress(progress, item_id, stage_id) do
    case Map.get(progress, item_id) do
      nil ->
        progress

      item_progress ->
        updated = Map.delete(item_progress, stage_id)

        if updated == %{} do
          Map.delete(progress, item_id)
        else
          Map.put(progress, item_id, updated)
        end
    end
  end
end
```

- [ ] **Step 4: Add Tracker to supervision tree**

In `lib/cham/application.ex`, add after the Config Manager:

```elixir
Cham.JobTracking.Tracker,
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
mix test test/cham/job_tracking/tracker_test.exs
```

Expected: all 5 tests pass.

- [ ] **Step 6: Run all tests**

```bash
mix test
```

Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add lib/cham/job_tracking/tracker.ex test/cham/job_tracking/tracker_test.exs lib/cham/application.ex
git commit -m "feat: add Job Tracking with stage history and ephemeral progress

GenServer that subscribes to pipeline events, records stage execution
history in the database (started/completed/failed/snoozed), and holds
ephemeral intra-stage progress in memory for real-time UI display."
```

---

## Verification

After all tasks, run:

```bash
mix format --check-formatted
mix test
```

All should pass with zero warnings.
