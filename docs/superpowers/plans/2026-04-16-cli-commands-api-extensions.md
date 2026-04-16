# CLI Commands & API Extensions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add delete, cancel, retry, follow, and open CLI commands with supporting server-side API endpoints, SSE event streaming, and an interactive stage picker for reprocess.

**Architecture:** Server-side changes extend the existing Phoenix controllers and Pipeline module. A new SSE controller uses Plug chunked responses with EventBus subscriptions. The CLI gains new commands that call these endpoints, plus a Rich Live display for the follow command. The "cancelled" status is added as a new terminal state.

**Tech Stack:** Elixir/Phoenix (server), Python/Click/Rich/httpx/InquirerPy (CLI)

**Spec:** `docs/superpowers/specs/2026-04-16-cli-commands-api-extensions-design.md`

---

## File Structure

### Server-side (Elixir)

| Action | File | Responsibility |
|--------|------|----------------|
| Modify | `lib/cham/items/item.ex` | Add "cancelled" to valid statuses |
| Modify | `lib/cham/items.ex` | Add `delete_item_with_files/2`, `list_stage_executions/1` |
| Modify | `lib/cham/pipeline.ex` | Add `cancel/1` |
| Modify | `lib/cham/pipeline/orchestrator.ex` | Add "cancelled" to terminal statuses |
| Modify | `lib/cham/pipeline/stage_worker.ex` | Check item status before writing artifacts |
| Modify | `lib/cham_web/router.ex` | Add delete, cancel, retry, events routes |
| Modify | `lib/cham_web/controllers/item_controller.ex` | Add delete, cancel, retry actions; enrich show |
| Modify | `lib/cham_web/controllers/item_json.ex` | Add stage_executions and artifacts rendering |
| Create | `lib/cham_web/controllers/event_controller.ex` | SSE streaming endpoint |

### CLI (Python)

| Action | File | Responsibility |
|--------|------|----------------|
| Modify | `cli/pyproject.toml` | Add InquirerPy dependency |
| Modify | `cli/cham_cli/client.py` | Add delete, cancel, retry, stream_events methods |
| Modify | `cli/cham_cli/commands/item.py` | Add delete, cancel, retry, follow, open commands; enhance add and reprocess |
| Modify | `cli/cham_cli/output.py` | Add follow/live display formatting |

### Tests

| Action | File | What it tests |
|--------|------|---------------|
| Modify | `test/cham_web/controllers/item_controller_test.exs` | Delete, cancel, retry, enriched show |
| Create | `test/cham_web/controllers/event_controller_test.exs` | SSE streaming |
| Modify | `test/cham/pipeline_test.exs` | Cancel function |

---

## Task 1: Add "cancelled" status to Item schema and Orchestrator

This task adds the foundational status change that all other tasks depend on.

**Files:**
- Modify: `lib/cham/items/item.ex:26` — add "cancelled" to `@statuses`
- Modify: `lib/cham/pipeline/orchestrator.ex:18` — add "cancelled" to `@terminal_statuses`

- [ ] **Step 1: Update Item schema statuses**

In `lib/cham/items/item.ex`, change line 26:

```elixir
@statuses ~w(bootstrapping processing complete incomplete failed cancelled)
```

- [ ] **Step 2: Update Orchestrator terminal statuses**

In `lib/cham/pipeline/orchestrator.ex`, change line 18:

```elixir
@terminal_statuses ~w(complete incomplete failed cancelled)
```

- [ ] **Step 3: Run existing tests to verify no regressions**

Run: `mix test`
Expected: All existing tests pass. Adding a new valid status value should not break anything.

- [ ] **Step 4: Commit**

```bash
git add lib/cham/items/item.ex lib/cham/pipeline/orchestrator.ex
git commit -m "feat: add cancelled status to item schema and orchestrator"
```

---

## Task 2: Add Pipeline.cancel/1 and StageWorker cancellation guard

**Files:**
- Modify: `lib/cham/pipeline.ex` — add `cancel/1`
- Modify: `lib/cham/pipeline/stage_worker.ex:14-39` — add status check before writing artifacts
- Modify: `test/cham/pipeline_test.exs` — add cancel tests

- [ ] **Step 1: Write tests for Pipeline.cancel/1**

Add to `test/cham/pipeline_test.exs`:

```elixir
describe "cancel/1" do
  test "sets item status to cancelled", %{root: root} do
    {:ok, item} = Pipeline.submit_url("https://example.com/cancel-test", root: root)
    assert {:ok, updated} = Pipeline.cancel(item.id)
    assert updated.status == "cancelled"
  end

  test "returns error for already terminal item", %{root: root} do
    {:ok, item} = Pipeline.submit_url("https://example.com/cancel-terminal", root: root)
    {:ok, _} = Cham.Items.update_item(item, %{status: "complete"})
    assert {:error, :already_terminal} = Pipeline.cancel(item.id)
  end

  test "returns error for non-existent item" do
    assert {:error, :not_found} = Pipeline.cancel(Ecto.UUID.generate())
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/cham/pipeline_test.exs --seed 0`
Expected: FAIL — `Pipeline.cancel/1` is undefined.

- [ ] **Step 3: Implement Pipeline.cancel/1**

Add to `lib/cham/pipeline.ex`, after the `reprocess/2` function:

```elixir
@terminal_statuses ~w(complete incomplete failed cancelled)

@doc """
Cancel an in-progress item. Sets status to "cancelled" and cancels
all pending Oban jobs for the item. Currently executing jobs will
finish but their results are discarded by StageWorker.
"""
def cancel(item_id) do
  case Items.get_item(item_id) do
    nil ->
      {:error, :not_found}

    %{status: status} when status in @terminal_statuses ->
      {:error, :already_terminal}

    item ->
      cancel_oban_jobs(item_id)

      case Items.update_item(item, %{status: "cancelled"}) do
        {:ok, updated} ->
          Cham.EventBus.publish("item:status_changed", %{
            item_id: updated.id,
            status: "cancelled"
          })

          {:ok, updated}

        {:error, changeset} ->
          {:error, changeset}
      end
  end
end

defp cancel_oban_jobs(item_id) do
  import Ecto.Query

  active_states = ~w(available executing scheduled retryable)

  job_ids =
    Cham.Repo.all(
      from j in "oban_jobs",
        where:
          j.worker == "Cham.Pipeline.StageWorker" and
            j.state in ^active_states and
            fragment("?->>'item_id' = ?", j.args, ^item_id),
        select: j.id
    )

  Enum.each(job_ids, &Oban.cancel_job(Cham.Oban, &1))
end
```

- [ ] **Step 4: Add cancellation guard to StageWorker**

In `lib/cham/pipeline/stage_worker.ex`, modify the `perform/1` function. Replace the existing function body (lines 14-39) with:

```elixir
@impl Oban.Worker
def perform(%Oban.Job{args: args}) do
  item_id = args["item_id"]
  stage_module = String.to_existing_atom(args["stage_module"])
  plugin_id = args["plugin_id"]

  item = Items.get_item!(item_id)

  # Skip execution if item has been cancelled
  if item.status == "cancelled" do
    Logger.info("Skipping stage #{plugin_id} for cancelled item #{item_id}")
    {:cancel, :item_cancelled}
  else
    item_dir = resolve_item_dir(item)

    case execute_stage(stage_module, plugin_id, item, item_dir) do
      {:ok, _stage_dir} ->
        # Re-check status before notifying orchestrator
        refreshed = Items.get_item!(item_id)

        if refreshed.status == "cancelled" do
          Logger.info("Item #{item_id} was cancelled during stage #{plugin_id}, discarding results")
          {:cancel, :item_cancelled}
        else
          Cham.Pipeline.Orchestrator.stage_completed(item_id, plugin_id)
          :ok
        end

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
end
```

- [ ] **Step 5: Run tests**

Run: `mix test test/cham/pipeline_test.exs --seed 0`
Expected: All tests pass including the new cancel tests.

- [ ] **Step 6: Run full test suite**

Run: `mix test`
Expected: All tests pass.

- [ ] **Step 7: Commit**

```bash
git add lib/cham/pipeline.ex lib/cham/pipeline/stage_worker.ex test/cham/pipeline_test.exs
git commit -m "feat: add Pipeline.cancel/1 with Oban job cancellation and StageWorker guard"
```

---

## Task 3: Add Items.delete_item_with_files/2 and list_stage_executions/1

**Files:**
- Modify: `lib/cham/items.ex` — add `delete_item_with_files/2`, `list_stage_executions/1`
- Create: `test/cham/items_delete_test.exs` — delete tests

- [ ] **Step 1: Write tests for delete_item_with_files and list_stage_executions**

Create `test/cham/items_delete_test.exs`:

```elixir
defmodule Cham.Items.DeleteTest do
  use Cham.DataCase

  alias Cham.Items

  setup do
    tmp = Path.join(System.tmp_dir!(), "cham_delete_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    %{tmp: tmp}
  end

  describe "delete_item_with_files/2" do
    test "deletes item and associated files", %{tmp: tmp} do
      item_dir = Path.join(tmp, "test-item")
      File.mkdir_p!(item_dir)
      File.write!(Path.join(item_dir, "test.txt"), "hello")

      {:ok, item} = Items.create_item(%{url: "https://example.com/delete-1", archive_path: item_dir})
      {:ok, _} = Items.create_artifact(%{item_id: item.id, stage: "input", labels: %{}, path: "processing/input", filenames: []})

      assert :ok = Items.delete_item_with_files(item)
      assert Items.get_item(item.id) == nil
      refute File.dir?(item_dir)
    end

    test "deletes item with keep_files option", %{tmp: tmp} do
      item_dir = Path.join(tmp, "test-item-keep")
      File.mkdir_p!(item_dir)
      File.write!(Path.join(item_dir, "test.txt"), "hello")

      {:ok, item} = Items.create_item(%{url: "https://example.com/delete-2", archive_path: item_dir})

      assert :ok = Items.delete_item_with_files(item, keep_files: true)
      assert Items.get_item(item.id) == nil
      assert File.dir?(item_dir)
    end

    test "deletes item with bootstrap_path when no archive_path", %{tmp: tmp} do
      item_dir = Path.join(tmp, "bootstrap-item")
      File.mkdir_p!(item_dir)

      {:ok, item} = Items.create_item(%{url: "https://example.com/delete-3", bootstrap_path: item_dir})

      assert :ok = Items.delete_item_with_files(item)
      assert Items.get_item(item.id) == nil
      refute File.dir?(item_dir)
    end

    test "deletes item when no paths exist" do
      {:ok, item} = Items.create_item(%{url: "https://example.com/delete-4"})

      assert :ok = Items.delete_item_with_files(item)
      assert Items.get_item(item.id) == nil
    end
  end

  describe "list_stage_executions/1" do
    test "returns stage executions for an item" do
      {:ok, item} = Items.create_item(%{url: "https://example.com/exec-1"})

      Cham.Repo.insert!(%Cham.JobTracking.StageExecution{
        item_id: item.id,
        stage: "download",
        status: "completed",
        attempt: 1,
        started_at: DateTime.utc_now(),
        ended_at: DateTime.utc_now(),
        duration_ms: 500
      })

      executions = Items.list_stage_executions(item.id)
      assert length(executions) == 1
      assert hd(executions).stage == "download"
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/cham/items_delete_test.exs --seed 0`
Expected: FAIL — functions not defined.

- [ ] **Step 3: Implement delete_item_with_files/2 and list_stage_executions/1**

Add to `lib/cham/items.ex`:

```elixir
@doc """
Delete an item and optionally its archive files.
Files are deleted by default. Pass `keep_files: true` to preserve them.
Associated DB records (artifacts, stage_executions, messages) are
cascade-deleted by the database foreign key constraints.
"""
def delete_item_with_files(%Item{} = item, opts \\ []) do
  keep_files = Keyword.get(opts, :keep_files, false)

  unless keep_files do
    path = item.archive_path || item.bootstrap_path

    if path && File.dir?(path) do
      File.rm_rf!(path)
    end
  end

  case Repo.delete(item) do
    {:ok, _} -> :ok
    {:error, changeset} -> {:error, changeset}
  end
end

def list_stage_executions(item_id) do
  Cham.JobTracking.StageExecution
  |> where([s], s.item_id == ^item_id)
  |> order_by([s], asc: s.started_at)
  |> Repo.all()
end
```

- [ ] **Step 4: Run tests**

Run: `mix test test/cham/items_delete_test.exs --seed 0`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/cham/items.ex test/cham/items_delete_test.exs
git commit -m "feat: add Items.delete_item_with_files/2 and list_stage_executions/1"
```

---

## Task 4: Add delete, cancel, retry API endpoints and enrich show

**Files:**
- Modify: `lib/cham_web/router.ex` — add new routes
- Modify: `lib/cham_web/controllers/item_controller.ex` — add delete, cancel, retry actions; enrich show
- Modify: `lib/cham_web/controllers/item_json.ex` — add stage_executions and artifacts rendering
- Modify: `test/cham_web/controllers/item_controller_test.exs` — add tests for new endpoints

- [ ] **Step 1: Write tests for the new endpoints**

Add to `test/cham_web/controllers/item_controller_test.exs`:

```elixir
describe "DELETE /api/v1/items/:id" do
  test "deletes an item and returns 204", %{conn: conn} do
    {:ok, item} = Items.create_item(%{url: "https://example.com/delete-1"})

    conn = delete(conn, "/api/v1/items/#{item.id}")
    assert response(conn, 204)
    assert Items.get_item(item.id) == nil
  end

  test "deletes with keep_files=true preserves files", %{conn: conn} do
    {:ok, item} = Items.create_item(%{url: "https://example.com/delete-2"})

    conn = delete(conn, "/api/v1/items/#{item.id}?keep_files=true")
    assert response(conn, 204)
    assert Items.get_item(item.id) == nil
  end

  test "returns 404 for non-existent item", %{conn: conn} do
    conn = delete(conn, "/api/v1/items/#{Ecto.UUID.generate()}")
    assert %{"error" => "not found"} = json_response(conn, 404)
  end
end

describe "POST /api/v1/items/:id/cancel" do
  test "cancels a processing item", %{conn: conn} do
    {:ok, item} = Items.create_item(%{url: "https://example.com/cancel-1", status: "processing"})

    conn = post(conn, "/api/v1/items/#{item.id}/cancel")
    assert %{"status" => "cancelled"} = json_response(conn, 200)
  end

  test "returns 409 for already terminal item", %{conn: conn} do
    {:ok, item} = Items.create_item(%{url: "https://example.com/cancel-2", status: "complete"})

    conn = post(conn, "/api/v1/items/#{item.id}/cancel")
    assert %{"error" => _} = json_response(conn, 409)
  end

  test "returns 404 for non-existent item", %{conn: conn} do
    conn = post(conn, "/api/v1/items/#{Ecto.UUID.generate()}/cancel")
    assert %{"error" => "not found"} = json_response(conn, 404)
  end
end

describe "POST /api/v1/items/:id/retry" do
  test "retries a failed item", %{conn: conn} do
    {:ok, item} = Items.create_item(%{url: "https://example.com/retry-1", status: "failed"})

    conn = post(conn, "/api/v1/items/#{item.id}/retry")
    body = json_response(conn, 202)
    assert body["status"] in ["processing", "bootstrapping"]
  end

  test "returns 404 for non-existent item", %{conn: conn} do
    conn = post(conn, "/api/v1/items/#{Ecto.UUID.generate()}/retry")
    assert %{"error" => "not found"} = json_response(conn, 404)
  end
end

describe "GET /api/v1/items/:id (enriched)" do
  test "includes stage_executions and artifacts in response", %{conn: conn} do
    {:ok, item} = Items.create_item(%{url: "https://example.com/enriched-1"})

    Items.create_artifact(%{
      item_id: item.id,
      stage: "input",
      labels: %{"domain" => "example.com"},
      filenames: [],
      path: "processing/input-123",
      status: "produced"
    })

    Cham.Repo.insert!(%Cham.JobTracking.StageExecution{
      item_id: item.id,
      stage: "input",
      status: "completed",
      attempt: 1,
      started_at: DateTime.utc_now(),
      ended_at: DateTime.utc_now(),
      duration_ms: 100
    })

    conn = get(conn, "/api/v1/items/#{item.id}")
    body = json_response(conn, 200)

    assert is_list(body["stage_executions"])
    assert length(body["stage_executions"]) == 1
    assert hd(body["stage_executions"])["stage"] == "input"

    assert is_list(body["artifacts"])
    assert length(body["artifacts"]) == 1
    assert hd(body["artifacts"])["stage"] == "input"
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/cham_web/controllers/item_controller_test.exs --seed 0`
Expected: FAIL — routes and actions don't exist yet.

- [ ] **Step 3: Add routes**

In `lib/cham_web/router.ex`, replace the existing API scope (the one with `resources "/items"`) with:

```elixir
scope "/api/v1", ChamWeb do
  pipe_through :api

  resources "/items", ItemController, only: [:create, :index, :show, :delete]
  post "/items/:id/reprocess", ItemController, :reprocess
  post "/items/:id/cancel", ItemController, :cancel
  post "/items/:id/retry", ItemController, :retry
  get "/items/:id/events", EventController, :stream
end
```

- [ ] **Step 4: Add controller actions**

Add to `lib/cham_web/controllers/item_controller.ex`, after the `reprocess` function:

```elixir
def delete(conn, %{"id" => id} = params) do
  keep_files = params["keep_files"] == "true"

  case Items.get_item_by_slug_or_id(id) do
    {:ok, item} ->
      # Auto-cancel if in-progress
      if item.status in ~w(bootstrapping processing) do
        Pipeline.cancel(item.id)
        # Reload to get updated status
        item = Items.get_item!(item.id)
      end

      case Items.delete_item_with_files(item, keep_files: keep_files) do
        :ok ->
          send_resp(conn, :no_content, "")

        {:error, _} ->
          conn
          |> put_status(:internal_server_error)
          |> put_view(ChamWeb.ItemJSON)
          |> render("error.json", error: "failed to delete item")
      end

    {:error, :not_found} ->
      conn
      |> put_status(:not_found)
      |> put_view(ChamWeb.ItemJSON)
      |> render("error.json", error: "not found")
  end
end

def cancel(conn, %{"id" => id}) do
  case Items.get_item_by_slug_or_id(id) do
    {:ok, item} ->
      case Pipeline.cancel(item.id) do
        {:ok, updated} ->
          conn
          |> put_view(ChamWeb.ItemJSON)
          |> render("show.json", item: updated)

        {:error, :already_terminal} ->
          conn
          |> put_status(:conflict)
          |> put_view(ChamWeb.ItemJSON)
          |> render("error.json", error: "item is already in a terminal status")
      end

    {:error, :not_found} ->
      conn
      |> put_status(:not_found)
      |> put_view(ChamWeb.ItemJSON)
      |> render("error.json", error: "not found")
  end
end

def retry(conn, %{"id" => id} = params) do
  from_stage = params["from_stage"]

  case Items.get_item_by_slug_or_id(id) do
    {:ok, item} ->
      opts = [retry_failed: true]
      opts = if from_stage, do: Keyword.put(opts, :invalidate, [from_stage]), else: opts

      case Pipeline.reprocess(item.id, opts) do
        {:ok, updated} ->
          conn
          |> put_status(:accepted)
          |> put_view(ChamWeb.ItemJSON)
          |> render("show.json", item: updated)

        {:error, _} ->
          conn
          |> put_status(:unprocessable_entity)
          |> put_view(ChamWeb.ItemJSON)
          |> render("error.json", error: "failed to retry item")
      end

    {:error, :not_found} ->
      conn
      |> put_status(:not_found)
      |> put_view(ChamWeb.ItemJSON)
      |> render("error.json", error: "not found")
  end
end
```

- [ ] **Step 5: Enrich the show action**

In `lib/cham_web/controllers/item_controller.ex`, replace the existing `show/2` function:

```elixir
def show(conn, %{"id" => id}) do
  case Items.get_item_by_slug_or_id(id) do
    {:ok, item} ->
      artifacts = Items.list_artifacts(item.id)
      stage_executions = Items.list_stage_executions(item.id)

      conn
      |> put_view(ChamWeb.ItemJSON)
      |> render("show_detail.json",
        item: item,
        artifacts: artifacts,
        stage_executions: stage_executions
      )

    {:error, :not_found} ->
      conn
      |> put_status(:not_found)
      |> put_view(ChamWeb.ItemJSON)
      |> render("error.json", error: "not found")
  end
end
```

- [ ] **Step 6: Update ItemJSON with enriched rendering**

Replace the contents of `lib/cham_web/controllers/item_json.ex`:

```elixir
defmodule ChamWeb.ItemJSON do
  def render("index.json", %{items: items}) do
    %{items: Enum.map(items, &item_json/1)}
  end

  def render("show.json", %{item: item}) do
    item_json(item)
  end

  def render("show_detail.json", %{item: item, artifacts: artifacts, stage_executions: stage_executions}) do
    item_json(item)
    |> Map.put(:artifacts, Enum.map(artifacts, &artifact_json/1))
    |> Map.put(:stage_executions, Enum.map(stage_executions, &stage_execution_json/1))
  end

  def render("error.json", %{error: message}) do
    %{error: message}
  end

  defp item_json(item) do
    %{
      id: item.id,
      url: item.url,
      status: item.status,
      title: item.title,
      slug: item.slug,
      content_type: item.content_type,
      tags: item.tags,
      error_message: item.error_message,
      metadata: item.metadata,
      inserted_at: item.inserted_at,
      updated_at: item.updated_at
    }
  end

  defp artifact_json(artifact) do
    %{
      stage: artifact.stage,
      labels: artifact.labels,
      filenames: artifact.filenames,
      status: artifact.status
    }
  end

  defp stage_execution_json(execution) do
    %{
      stage: execution.stage,
      status: execution.status,
      attempt: execution.attempt,
      duration_ms: execution.duration_ms,
      error: execution.error,
      inserted_at: execution.inserted_at
    }
  end
end
```

- [ ] **Step 7: Run tests**

Run: `mix test test/cham_web/controllers/item_controller_test.exs --seed 0`
Expected: All tests pass.

- [ ] **Step 8: Run full test suite**

Run: `mix test`
Expected: All tests pass. The `show` endpoint now returns a different structure (`show_detail.json`), which existing tests for `show` should still match since the base fields are the same and tests don't assert absence of extra keys.

- [ ] **Step 9: Commit**

```bash
git add lib/cham_web/router.ex lib/cham_web/controllers/item_controller.ex lib/cham_web/controllers/item_json.ex test/cham_web/controllers/item_controller_test.exs
git commit -m "feat: add delete, cancel, retry API endpoints and enrich show response"
```

---

## Task 5: SSE Event Streaming Controller

**Files:**
- Create: `lib/cham_web/controllers/event_controller.ex`
- Create: `test/cham_web/controllers/event_controller_test.exs`

- [ ] **Step 1: Write tests for SSE streaming**

Create `test/cham_web/controllers/event_controller_test.exs`:

```elixir
defmodule ChamWeb.EventControllerTest do
  use ChamWeb.ConnCase

  alias Cham.Items
  alias Cham.Pipeline.Events.{StageStarted, StageCompleted, StageFailed}

  describe "GET /api/v1/items/:id/events" do
    test "returns 404 for non-existent item", %{conn: conn} do
      conn = get(conn, "/api/v1/items/#{Ecto.UUID.generate()}/events")
      assert %{"error" => "not found"} = json_response(conn, 404)
    end

    test "returns event stream headers for existing item", %{conn: conn} do
      {:ok, item} = Items.create_item(%{url: "https://example.com/sse-1", status: "processing"})

      # We need to test the SSE endpoint in a spawned process since it blocks.
      # Instead, we test that the controller correctly validates the item exists
      # and test event formatting separately.

      # For a terminal item, the controller should send current status and close
      {:ok, _} = Items.update_item(item, %{status: "complete"})

      conn = get(conn, "/api/v1/items/#{item.id}/events")
      assert {"content-type", "text/event-stream"} in conn.resp_headers
      assert conn.resp_body =~ "event: item_status_changed"
      assert conn.resp_body =~ "complete"
    end
  end

  describe "event formatting" do
    test "format_sse_event/2 formats stage_started" do
      event = %StageStarted{stage_id: "download", item_id: "abc", attempt: 1}
      result = ChamWeb.EventController.format_sse_event("stage_started", event)
      assert result =~ "event: stage_started\n"
      assert result =~ "\"stage_id\":\"download\""
    end

    test "format_sse_event/2 formats stage_completed" do
      event = %StageCompleted{stage_id: "download", item_id: "abc", duration_ms: 500}
      result = ChamWeb.EventController.format_sse_event("stage_completed", event)
      assert result =~ "event: stage_completed\n"
      assert result =~ "\"duration_ms\":500"
    end

    test "format_sse_event/2 formats stage_failed" do
      event = %StageFailed{stage_id: "download", item_id: "abc", error: "timeout"}
      result = ChamWeb.EventController.format_sse_event("stage_failed", event)
      assert result =~ "event: stage_failed\n"
      assert result =~ "\"error\":\"timeout\""
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/cham_web/controllers/event_controller_test.exs --seed 0`
Expected: FAIL — `EventController` doesn't exist.

- [ ] **Step 3: Implement EventController**

Create `lib/cham_web/controllers/event_controller.ex`:

```elixir
defmodule ChamWeb.EventController do
  use ChamWeb, :controller

  alias Cham.Items
  alias Cham.Pipeline.Events.{StageStarted, StageCompleted, StageFailed, StageSnoozed}

  @terminal_statuses ~w(complete incomplete failed cancelled)
  @keepalive_interval 15_000

  def stream(conn, %{"id" => id}) do
    case Items.get_item_by_slug_or_id(id) do
      {:ok, item} ->
        if item.status in @terminal_statuses do
          # Item already terminal — send current status and close
          conn
          |> put_resp_content_type("text/event-stream")
          |> send_resp(
            200,
            format_sse_event("item_status_changed", %{
              item_id: item.id,
              status: item.status
            })
          )
        else
          stream_events(conn, item)
        end

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> put_view(ChamWeb.ItemJSON)
        |> json(%{error: "not found"})
    end
  end

  defp stream_events(conn, item) do
    # Subscribe to pipeline and item events
    Cham.EventBus.subscribe("pipeline")
    Cham.EventBus.subscribe("item")

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> send_chunked(200)

    schedule_keepalive()
    listen_loop(conn, item.id)
  end

  defp listen_loop(conn, item_id) do
    receive do
      %StageStarted{item_id: ^item_id} = event ->
        case chunk_sse(conn, "stage_started", %{
               stage_id: event.stage_id,
               item_id: event.item_id,
               attempt: event.attempt
             }) do
          {:ok, conn} -> listen_loop(conn, item_id)
          {:error, _} -> conn
        end

      %StageCompleted{item_id: ^item_id} = event ->
        case chunk_sse(conn, "stage_completed", %{
               stage_id: event.stage_id,
               item_id: event.item_id,
               duration_ms: event.duration_ms
             }) do
          {:ok, conn} -> listen_loop(conn, item_id)
          {:error, _} -> conn
        end

      %StageFailed{item_id: ^item_id} = event ->
        case chunk_sse(conn, "stage_failed", %{
               stage_id: event.stage_id,
               item_id: event.item_id,
               error: event.error
             }) do
          {:ok, conn} -> listen_loop(conn, item_id)
          {:error, _} -> conn
        end

      %StageSnoozed{item_id: ^item_id} = event ->
        case chunk_sse(conn, "stage_snoozed", %{
               stage_id: event.stage_id,
               item_id: event.item_id,
               reason: event.reason
             }) do
          {:ok, conn} -> listen_loop(conn, item_id)
          {:error, _} -> conn
        end

      %{item_id: ^item_id, status: status} when status in @terminal_statuses ->
        chunk_sse(conn, "item_status_changed", %{item_id: item_id, status: status})
        conn

      :keepalive ->
        case Plug.Conn.chunk(conn, ": keepalive\n\n") do
          {:ok, conn} ->
            schedule_keepalive()
            listen_loop(conn, item_id)

          {:error, _} ->
            conn
        end

      _ ->
        listen_loop(conn, item_id)
    end
  end

  defp chunk_sse(conn, event_type, data) do
    sse_frame = format_sse_event(event_type, data)
    Plug.Conn.chunk(conn, sse_frame)
  end

  defp schedule_keepalive do
    Process.send_after(self(), :keepalive, @keepalive_interval)
  end

  @doc """
  Format a Server-Sent Event frame. Public for testing.
  """
  def format_sse_event(event_type, data) do
    json_data =
      case data do
        %{__struct__: _} -> data |> Map.from_struct() |> Jason.encode!()
        _ -> Jason.encode!(data)
      end

    "event: #{event_type}\ndata: #{json_data}\n\n"
  end
end
```

- [ ] **Step 4: Run tests**

Run: `mix test test/cham_web/controllers/event_controller_test.exs --seed 0`
Expected: All tests pass.

- [ ] **Step 5: Run full test suite**

Run: `mix test`
Expected: All tests pass.

- [ ] **Step 6: Commit**

```bash
git add lib/cham_web/controllers/event_controller.ex test/cham_web/controllers/event_controller_test.exs
git commit -m "feat: add SSE event streaming controller for real-time pipeline progress"
```

---

## Task 6: CLI client module extensions

**Files:**
- Modify: `cli/cham_cli/client.py` — add delete_item, cancel_item, retry_item, stream_events methods

- [ ] **Step 1: Add new client methods**

In `cli/cham_cli/client.py`, add these methods to the `ChamClient` class, before `_request`:

```python
def delete_item(self, id_or_slug: str, keep_files: bool = False) -> dict:
    """Delete an item via DELETE /api/v1/items/:id."""
    params = {}
    if keep_files:
        params["keep_files"] = "true"
    return self._request("DELETE", f"/api/v1/items/{id_or_slug}", params=params)

def cancel_item(self, id_or_slug: str) -> dict:
    """Cancel an item via POST /api/v1/items/:id/cancel."""
    return self._request("POST", f"/api/v1/items/{id_or_slug}/cancel")

def retry_item(
    self, id_or_slug: str, from_stage: Optional[str] = None
) -> dict:
    """Retry a failed item via POST /api/v1/items/:id/retry."""
    payload: dict[str, Any] = {}
    if from_stage:
        payload["from_stage"] = from_stage
    return self._request("POST", f"/api/v1/items/{id_or_slug}/retry", json=payload)

def stream_events(self, id_or_slug: str):
    """Stream SSE events for an item. Yields (event_type, data_dict) tuples."""
    url = f"{self.base_url}/api/v1/items/{id_or_slug}/events"
    headers = dict(self._client.headers)

    try:
        with httpx.stream("GET", url, headers=headers, timeout=None) as response:
            if response.status_code == 404:
                print("Error: item not found", file=sys.stderr)
                sys.exit(1)
            if response.status_code >= 400:
                print(f"Error: {response.status_code}", file=sys.stderr)
                sys.exit(1)

            event_type = None
            for line in response.iter_lines():
                if line.startswith("event: "):
                    event_type = line[7:]
                elif line.startswith("data: ") and event_type:
                    import json
                    data = json.loads(line[6:])
                    yield (event_type, data)
                    event_type = None
                elif line.startswith(":"):
                    # Comment/keepalive, ignore
                    pass
    except httpx.ConnectError:
        print(
            f"Error: could not connect to server at {self.base_url}",
            file=sys.stderr,
        )
        sys.exit(1)
```

- [ ] **Step 2: Commit**

```bash
git add cli/cham_cli/client.py
git commit -m "feat: add delete, cancel, retry, stream_events to CLI client"
```

---

## Task 7: CLI follow display and output helpers

**Files:**
- Modify: `cli/cham_cli/output.py` — add follow display function

- [ ] **Step 1: Add follow display functions**

Add to `cli/cham_cli/output.py`:

```python
def format_follow_event_json(event_type: str, data: dict) -> None:
    """Print a single event as NDJSON line."""
    import json
    print(json.dumps({"event": event_type, **data}, default=str))


def run_follow_display(client, id_or_slug: str, use_json: bool = False) -> None:
    """
    Connect to SSE stream and display live progress.
    In TTY mode, uses Rich Live display. In non-TTY/json mode, prints NDJSON.
    """
    if use_json or not is_tty():
        for event_type, data in client.stream_events(id_or_slug):
            format_follow_event_json(event_type, data)
            if event_type == "item_status_changed":
                break
        return

    from rich.live import Live
    from rich.table import Table

    console = Console()
    stages: dict[str, dict] = {}
    final_status = None

    def build_table() -> Table:
        table = Table(title="Pipeline Progress", show_header=True, header_style="bold")
        table.add_column("Stage", style="cyan")
        table.add_column("Status")
        table.add_column("Duration")

        for stage_id, info in stages.items():
            status = info.get("status", "unknown")
            color = STATUS_COLORS.get(status, "white")
            duration = info.get("duration", "—")
            table.add_row(stage_id, f"[{color}]{status}[/{color}]", str(duration))

        return table

    try:
        with Live(build_table(), console=console, refresh_per_second=4) as live:
            for event_type, data in client.stream_events(id_or_slug):
                stage_id = data.get("stage_id")

                if event_type == "stage_started":
                    stages[stage_id] = {"status": "processing", "duration": "..."}
                elif event_type == "stage_completed":
                    duration_ms = data.get("duration_ms", 0)
                    stages[stage_id] = {
                        "status": "complete",
                        "duration": f"{duration_ms / 1000:.1f}s",
                    }
                elif event_type == "stage_failed":
                    error = data.get("error", "unknown")
                    stages[stage_id] = {"status": "failed", "duration": error}
                elif event_type == "stage_snoozed":
                    reason = data.get("reason", "")
                    stages[stage_id] = {"status": "snoozed", "duration": reason}
                elif event_type == "item_status_changed":
                    final_status = data.get("status", "unknown")
                    live.update(build_table())
                    break

                live.update(build_table())
    except KeyboardInterrupt:
        console.print("\n[dim]Detached. Processing continues on the server.[/dim]")
        return

    if final_status:
        color = STATUS_COLORS.get(final_status, "white")
        console.print(f"\nPipeline [{color}]{final_status}[/{color}]")
```

Also add the `"snoozed"` and `"cancelled"` entries to `STATUS_COLORS`:

Update the `STATUS_COLORS` dict at the top of the file:

```python
STATUS_COLORS = {
    "bootstrapping": "blue",
    "processing": "yellow",
    "complete": "green",
    "incomplete": "dark_orange",
    "failed": "red",
    "cancelled": "magenta",
    "snoozed": "cyan",
}
```

- [ ] **Step 2: Commit**

```bash
git add cli/cham_cli/output.py
git commit -m "feat: add follow display with Rich Live and NDJSON output to CLI"
```

---

## Task 8: CLI commands — delete, cancel, retry, follow, open

**Files:**
- Modify: `cli/cham_cli/commands/item.py` — add new commands
- Modify: `cli/pyproject.toml` — add InquirerPy dependency

- [ ] **Step 1: Add InquirerPy dependency**

In `cli/pyproject.toml`, update the dependencies list:

```toml
dependencies = [
    "click>=8.1",
    "rich>=13.0",
    "httpx>=0.27",
    "InquirerPy>=0.3.4",
    "tomli-w>=1.0",
    "tomli>=2.0; python_version < '3.11'",
]
```

- [ ] **Step 2: Add new commands to item.py**

Replace `cli/cham_cli/commands/item.py` with the full updated file:

```python
"""Item commands: add, list, show, delete, cancel, retry, follow, open, reprocess."""

import sys
import webbrowser

import click

from cham_cli.config import load_config, get_server_url, get_api_key
from cham_cli.client import ChamClient
from cham_cli.output import format_item_table, format_item_detail, run_follow_display


def _make_client() -> ChamClient:
    config = load_config()
    return ChamClient(get_server_url(config), get_api_key(config))


@click.group()
def item():
    """Manage items."""
    pass


@item.command()
@click.argument("url")
@click.option("--tags", default="", help="Comma-separated tags")
@click.option("--follow", "do_follow", is_flag=True, help="Follow live progress after submit")
@click.option("--json", "use_json", is_flag=True, help="Output as JSON")
def add(url: str, tags: str, do_follow: bool, use_json: bool):
    """Submit a URL for archiving."""
    client = _make_client()
    tag_list = [t.strip() for t in tags.split(",") if t.strip()] if tags else []
    result = client.submit_item(url, tag_list)
    item_data = result.get("data", result) if isinstance(result, dict) else result

    if do_follow:
        item_id = item_data.get("id")
        if item_id:
            run_follow_display(client, item_id, use_json=use_json)
        else:
            format_item_detail(item_data, use_json=use_json)
    else:
        format_item_detail(item_data, use_json=use_json)


@item.command("list")
@click.option("--status", default=None, help="Filter by status")
@click.option("--type", "content_type", default=None, help="Filter by content type")
@click.option("--tag", default=None, help="Filter by tag")
@click.option("--json", "use_json", is_flag=True, help="Output as JSON")
def list_items(status: str, content_type: str, tag: str, use_json: bool):
    """List items."""
    client = _make_client()
    items = client.list_items(status=status, content_type=content_type, tag=tag)
    format_item_table(items, use_json=use_json)


@item.command()
@click.argument("id_or_slug")
@click.option("--json", "use_json", is_flag=True, help="Output as JSON")
def show(id_or_slug: str, use_json: bool):
    """Show item details."""
    client = _make_client()
    result = client.get_item(id_or_slug)
    item_data = result.get("data", result) if isinstance(result, dict) else result
    format_item_detail(item_data, use_json=use_json)


@item.command()
@click.argument("id_or_slug")
@click.option("--keep-files", is_flag=True, help="Keep archive files on disk")
@click.option("--yes", "-y", is_flag=True, help="Skip confirmation prompt")
@click.option("--json", "use_json", is_flag=True, help="Output as JSON")
def delete(id_or_slug: str, keep_files: bool, yes: bool, use_json: bool):
    """Delete an item and its archive files."""
    client = _make_client()

    # Fetch item details for confirmation prompt
    result = client.get_item(id_or_slug)
    item_data = result.get("data", result) if isinstance(result, dict) else result
    display_name = item_data.get("title") or item_data.get("url", id_or_slug)

    if not yes:
        if not sys.stdout.isatty():
            print("Error: --yes flag required for non-interactive delete", file=sys.stderr)
            sys.exit(2)
        msg = f"Delete '{display_name}'?"
        if not keep_files:
            msg += " Files will also be deleted."
        if not click.confirm(msg):
            print("Cancelled.")
            return

    client.delete_item(id_or_slug, keep_files=keep_files)

    if use_json:
        from cham_cli.output import print_json
        print_json({"deleted": True, "id": item_data.get("id")})
    else:
        print(f"Deleted: {display_name}")


@item.command()
@click.argument("id_or_slug")
@click.option("--json", "use_json", is_flag=True, help="Output as JSON")
def cancel(id_or_slug: str, use_json: bool):
    """Cancel an in-progress item."""
    client = _make_client()
    result = client.cancel_item(id_or_slug)
    item_data = result.get("data", result) if isinstance(result, dict) else result
    format_item_detail(item_data, use_json=use_json)


@item.command()
@click.argument("id_or_slug", required=False)
@click.option("--from-stage", default=None, help="Invalidate and retry from a specific stage")
@click.option("--all", "retry_all", is_flag=True, help="Retry all failed/incomplete items")
@click.option("--follow", "do_follow", is_flag=True, help="Follow live progress after retry")
@click.option("--json", "use_json", is_flag=True, help="Output as JSON")
def retry(id_or_slug: str, from_stage: str, retry_all: bool, do_follow: bool, use_json: bool):
    """Retry a failed or incomplete item."""
    client = _make_client()

    if retry_all:
        failed_items = client.list_items(status="failed")
        incomplete_items = client.list_items(status="incomplete")
        all_items = failed_items + incomplete_items

        if not all_items:
            print("No failed or incomplete items to retry.")
            return

        for item_data in all_items:
            item_id = item_data["id"]
            display = item_data.get("title") or item_data.get("url", item_id[:8])
            result = client.retry_item(item_id, from_stage=from_stage)
            print(f"Retrying: {display}")

        if use_json:
            from cham_cli.output import print_json
            print_json({"retried": len(all_items)})
        return

    if not id_or_slug:
        print("Error: provide an item ID/slug, or use --all", file=sys.stderr)
        sys.exit(2)

    result = client.retry_item(id_or_slug, from_stage=from_stage)
    item_data = result.get("data", result) if isinstance(result, dict) else result

    if do_follow:
        item_id = item_data.get("id")
        if item_id:
            run_follow_display(client, item_id, use_json=use_json)
        else:
            format_item_detail(item_data, use_json=use_json)
    else:
        format_item_detail(item_data, use_json=use_json)


@item.command()
@click.argument("id_or_slug")
@click.option("--json", "use_json", is_flag=True, help="Output as JSON")
def follow(id_or_slug: str, use_json: bool):
    """Follow live pipeline progress for an item."""
    client = _make_client()

    # Check if item exists and get current status
    result = client.get_item(id_or_slug)
    item_data = result.get("data", result) if isinstance(result, dict) else result
    status = item_data.get("status", "")

    if status in ("complete", "incomplete", "failed", "cancelled"):
        display = item_data.get("title") or item_data.get("url", id_or_slug)
        from cham_cli.output import _colored_status, is_tty
        if use_json or not is_tty():
            from cham_cli.output import print_json
            print_json({"status": status, "message": "item already terminal"})
        else:
            from rich.console import Console
            Console().print(f"'{display}' is already {status}.")
        return

    run_follow_display(client, item_data.get("id", id_or_slug), use_json=use_json)


@item.command()
@click.argument("id_or_slug")
def open(id_or_slug: str):
    """Open the item's original URL in the default browser."""
    client = _make_client()
    result = client.get_item(id_or_slug)
    item_data = result.get("data", result) if isinstance(result, dict) else result
    url = item_data.get("url")

    if not url:
        print("Error: item has no URL", file=sys.stderr)
        sys.exit(1)

    print(url)
    webbrowser.open(url)


@item.command()
@click.argument("id_or_slug")
@click.option("--retry-failed", is_flag=True, help="Also retry previously failed stages")
@click.option("--invalidate", "-i", multiple=True, help="Stage plugin_id to invalidate and re-run")
@click.option("--follow", "do_follow", is_flag=True, help="Follow live progress after reprocess")
@click.option("--json", "use_json", is_flag=True, help="Output as JSON")
def reprocess(id_or_slug: str, retry_failed: bool, invalidate: tuple, do_follow: bool, use_json: bool):
    """Reprocess an item, running any new or missing stages."""
    client = _make_client()

    invalidate_list = list(invalidate) if invalidate else None

    # Interactive stage picker when no --invalidate provided and in TTY mode
    if not invalidate_list and sys.stdout.isatty() and not use_json:
        result = client.get_item(id_or_slug)
        item_data = result.get("data", result) if isinstance(result, dict) else result
        executions = item_data.get("stage_executions", [])

        completed_stages = [
            e for e in executions if e.get("status") == "completed"
        ]

        if completed_stages:
            from InquirerPy import inquirer

            choices = [
                {"name": f"{e['stage']} ({e['status']})", "value": e["stage"]}
                for e in completed_stages
            ]

            selected = inquirer.checkbox(
                message="Select stages to invalidate and re-run:",
                choices=choices,
            ).execute()

            if selected:
                invalidate_list = selected

    result = client.reprocess_item(
        id_or_slug,
        retry_failed=retry_failed,
        invalidate=invalidate_list,
    )
    item_data = result.get("data", result) if isinstance(result, dict) else result

    if do_follow:
        item_id = item_data.get("id")
        if item_id:
            run_follow_display(client, item_id, use_json=use_json)
        else:
            format_item_detail(item_data, use_json=use_json)
    else:
        format_item_detail(item_data, use_json=use_json)
```

- [ ] **Step 3: Install updated dependencies**

Run from the `cli/` directory:

```bash
cd cli && uv pip install -e ".[dev]" 2>/dev/null || pip install -e .
```

- [ ] **Step 4: Verify CLI commands are registered**

```bash
cd cli && uv run cham item --help
```

Expected: all commands listed — add, cancel, delete, follow, list, open, reprocess, retry, show.

- [ ] **Step 5: Commit**

```bash
git add cli/pyproject.toml cli/cham_cli/commands/item.py
git commit -m "feat: add delete, cancel, retry, follow, open CLI commands and stage picker"
```

---

## Task 9: Final integration verification

- [ ] **Step 1: Run the full Elixir test suite**

```bash
mix test
```

Expected: All tests pass.

- [ ] **Step 2: Format code**

```bash
mix format
```

- [ ] **Step 3: Verify CLI help output**

```bash
cd cli && uv run cham item --help
```

Expected: All 9 commands listed.

- [ ] **Step 4: Commit any formatting changes**

```bash
git add -A && git diff --cached --stat
```

If there are formatting changes:

```bash
git commit -m "style: apply mix format"
```

