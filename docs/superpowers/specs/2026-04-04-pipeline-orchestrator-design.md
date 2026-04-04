# Pipeline Orchestrator — Design Spec

## Goal

Wire the existing pipeline components (StageWorker, DAG, Plugin Registry) together with an Orchestrator GenServer that schedules stage execution and manages item lifecycle transitions. After this, `Pipeline.submit_url/2` triggers a complete end-to-end pipeline run.

## Architecture

The Orchestrator is a GenServer that serializes all scheduling decisions and state transitions. Oban continues to manage concurrent stage execution via StageWorker. The split:

- **StageWorker (Oban.Worker)** — executes a single stage, writes results to DB and filesystem, publishes events. Unchanged except: after execution, notifies the Orchestrator.
- **Orchestrator (GenServer)** — receives notifications from StageWorker and submit_url. Evaluates the DAG, enqueues next stages, manages item status transitions (bootstrap → archive → terminal).

```
submit_url
  → create item + input artifact
  → Orchestrator.kick_off(item_id)
      → evaluate DAG → enqueue generic_download_url

StageWorker executes generic_download_url (Oban, :network queue)
  → writes artifacts to DB
  → Orchestrator.stage_completed(item_id, "generic_download_url")
      → evaluate DAG → enqueue content_type_router

StageWorker executes content_type_router (Oban, :general queue)
  → Orchestrator.stage_completed(...)
      → evaluate DAG → enqueue extract_article
      → check: all originals done? → yes → transition to archive

StageWorker executes extract_article
  → Orchestrator.stage_completed(...)
      → evaluate DAG → enqueue summarize_ollama, auto_tag, clean_title (parallel)

StageWorker executes summarize_ollama, auto_tag, clean_title (concurrent via Oban)
  → each calls Orchestrator.stage_completed(...)
      → evaluate DAG → no more stages ready
      → check: all stages done? → yes → status = "complete"
```

## Orchestrator GenServer

### Public API

```elixir
Orchestrator.kick_off(item_id)
# Called by Pipeline.submit_url after creating item + input artifact.
# Finds first ready stages, enqueues them via Oban.

Orchestrator.stage_completed(item_id, plugin_id)
# Called by StageWorker after successful stage execution.
# Evaluates next stages, checks transitions.

Orchestrator.stage_failed(item_id, plugin_id, error)
# Called by StageWorker when a stage fails permanently (all retries exhausted).
# Records failure, evaluates if pipeline can continue, checks terminal state.
```

All three are `cast` messages — fire-and-forget from the caller's perspective. The Orchestrator processes them sequentially.

### Internal Logic: `evaluate_and_enqueue(item_id)`

Shared logic called by all three handlers:

1. Fetch item from DB
2. Fetch all artifacts for the item (`Items.list_artifacts(item_id)`)
3. Build `completed_stage_ids` from artifacts with status `"produced"` (keyed by `stage` field)
4. Add permanently failed stage IDs (from stage_executions with status `"failed"`)
5. Get all registered stages from `Plugin.Registry.get_stages()`
6. Call `DAG.find_next_stages(stages, artifact_labels, completed_or_failed_ids)`
7. For each ready stage, insert an Oban job:
   ```elixir
   %{"item_id" => item_id, "stage_module" => to_string(stage.module), "plugin_id" => stage.plugin_id}
   |> Cham.Pipeline.StageWorker.new(queue: stage.queue)
   |> Oban.insert()
   ```

### Internal Logic: `check_transitions(item)`

Called after `evaluate_and_enqueue`. Handles item lifecycle:

**Bootstrap → Archive transition:**
- Condition: item status is `"bootstrapping"` AND `DAG.all_originals_complete?(stages, completed_ids)` is true
- Action:
  1. Generate slug from `item.title` (slugified) or fall back to URL-derived slug with a logged warning
  2. Call `ArchiveManager.move_to_archive(root, item.bootstrap_path, slug, Date.utc_today())`
  3. Update item: `status: "processing"`, `archive_path: new_path`, `slug: slug`, `bootstrap_path: nil`
  4. Re-run `evaluate_and_enqueue` to start derived stages

**Processing → Terminal:**
- Condition: item status is `"processing"` AND no stages are currently running (no pending/executing Oban jobs for this item) AND no new stages were enqueued
- Action:
  - If all stages that could run have produced artifacts → `"complete"`
  - If any stages failed → `"incomplete"`

**Bootstrap failure:**
- Condition: item status is `"bootstrapping"` AND a stage that produces `origin:original` artifacts has permanently failed
- Action: update item status to `"failed"`, set `error_message`

## Changes to Existing Modules

### `Pipeline.submit_url/2`

Add `Orchestrator.kick_off(item_id)` after successfully creating item and input artifact:

```elixir
with {:ok, item} <- Items.create_item(%{url: url, tags: tags}),
     {:ok, item} <- setup_bootstrap(item, root),
     {:ok, _artifact} <- create_input_artifact(item, url) do
  Orchestrator.kick_off(item.id)
  {:ok, item}
end
```

### `StageWorker.perform/1`

After successful execution, notify orchestrator:

```elixir
case execute_stage(stage_module, plugin_id, item, item_dir) do
  {:ok, _stage_dir} ->
    Orchestrator.stage_completed(item.id, plugin_id)
    :ok

  {:error, reason} ->
    # Oban handles retries. On final attempt failure,
    # Oban calls the worker's error handler.
    {:error, reason}

  {:snooze, duration_ms, reason} ->
    # ... existing snooze logic ...
    {:snooze, div(duration_ms, 1000)}
end
```

For permanent failures (all retries exhausted), implement Oban's `after_all_retries/1` callback to notify the orchestrator:

```elixir
def after_all_retries(%Oban.Job{args: args}) do
  Orchestrator.stage_failed(args["item_id"], args["plugin_id"], "all retries exhausted")
end
```

### `StageWorker.resolve_inputs/2`

Fix artifact path resolution — prepend item directory to the relative artifact path:

```elixir
# Current (broken): input_path: a.path  (relative, e.g. "processing/foo-20260404T...")
# Fixed: input_path: Path.join(item_dir, a.path)  (absolute)
```

The function needs `item_dir` as a parameter, resolved from the item's `archive_path` or `bootstrap_path`.

### `StageWorker.update_item_metadata/2`

Extend to handle all relevant columns and merge remainder into `item.metadata`:

```elixir
defp update_item_metadata(item, result) do
  meta = result[:item_metadata] || %{}

  # Promote known fields to dedicated columns
  column_updates =
    %{}
    |> maybe_put(:title, meta[:title] || meta["title"])
    |> maybe_put(:content_type, meta[:content_type] || meta["content_type"])
    |> maybe_put(:tags, meta[:tags] || meta["tags"])

  # Merge everything else into item.metadata
  known_keys = ["title", "content_type", "tags"]
  extra = meta
    |> stringify_keys()
    |> Map.drop(known_keys)

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

### `Application`

Add Orchestrator to supervision tree, after Plugin.Registry and before the Endpoint:

```elixir
Cham.Pipeline.Orchestrator,
```

## Slug Generation

At the bootstrap → archive transition:

1. If `item.title` is set: `Slug.generate(item.title)` — downcase, replace non-alphanumeric with hyphens, collapse consecutive hyphens, trim hyphens, append `-` + first 6 chars of item ID for uniqueness
2. If no title: derive from URL (`URI.parse(url).host <> URI.parse(url).path`), apply same slugification, log warning
3. Uniqueness guaranteed by the short ID suffix + DB unique constraint on slug

Slug generation is a private function in the Orchestrator, not a separate module.

## Dependencies

- `Cham.Pipeline.DAG` — `find_next_stages/3`, `all_originals_complete?/2`
- `Cham.Plugin.Registry` — `get_stages/0`
- `Cham.Items` — artifact queries, item updates
- `Cham.Archive.ArchiveManager` — `move_to_archive/4`
- `Oban` — job insertion

## Testing

- **Unit tests** for Orchestrator logic: mock Registry (start a test registry with test plugins), use DataCase for DB
- **Test kick_off**: create item with input artifact, verify Oban job enqueued
- **Test stage_completed**: create item with artifacts simulating a completed stage, verify next stage enqueued
- **Test bootstrap→archive transition**: create item with all originals complete, verify move and status change
- **Test terminal states**: complete, incomplete, failed scenarios
- **Test slug generation**: from title, from URL fallback
- **Integration test**: full submit_url → complete pipeline with test plugins (tagged :integration)
