# CLI Commands & API Extensions

Adds delete, retry, cancel, follow, and open commands to the CLI, an interactive stage picker for reprocess, and the server-side API endpoints to support them. Also adds SSE event streaming for real-time pipeline progress.

## New API Endpoints

### `DELETE /api/v1/items/:id`

Deletes an item and its associated archive files from disk by default. All associated DB records are cascade-deleted: artifacts, stage_executions, item_messages, then the item itself.

- **Default behavior**: deletes files from disk (archive_path or bootstrap_path) before removing DB records
- **Query param** `?keep_files=true`: preserves the archive directory on disk, only removes DB records
- **Returns**: 204 No Content on success
- **Errors**: 404 if item not found; 500 if file deletion fails (item remains intact)

Server-side implementation:
- `Cham.Items.delete_item_with_files/2` handles file removal + cascading DB deletes
- Deletes the directory at `item.archive_path` or `item.bootstrap_path` using `File.rm_rf/1`
- DB deletes in a transaction: artifacts, stage_executions, item_messages, then the item

### `POST /api/v1/items/:id/cancel`

Cancels an in-progress item. Sets status to `"cancelled"` and actively cancels all pending Oban jobs for the item.

- **Returns**: updated item JSON (200 OK)
- **Errors**: 404 if not found; 409 Conflict if item is already in a terminal status (complete, incomplete, failed, cancelled)

Server-side implementation:
- `Cham.Pipeline.cancel/1` sets item status to `"cancelled"`, then queries `oban_jobs` for all jobs with matching `item_id` in active states (available, executing, scheduled, retryable) and calls `Oban.cancel_job/1` on each
- Add `"cancelled"` to `@terminal_statuses` in `Cham.Pipeline.Orchestrator`

### `POST /api/v1/items/:id/retry`

Retries a failed/incomplete item by clearing failed stage executions and restarting the pipeline.

- **Optional body**: `{"from_stage": "stage_id"}` to also invalidate from a specific stage (clears that stage and all downstream stages)
- **Returns**: updated item JSON (202 Accepted)
- **Errors**: 404 if not found

Server-side implementation:
- Delegates to `Cham.Pipeline.reprocess/2` with `retry_failed: true` and optional `invalidate: [from_stage]`
- This is a convenience endpoint — functionally equivalent to reprocess with retry_failed, but with a clearer semantic for the common "retry what failed" use case

### `GET /api/v1/items/:id/events` (SSE)

Server-Sent Events stream for real-time pipeline progress on a single item.

- **Content-Type**: `text/event-stream`
- **Transfer-Encoding**: chunked
- **Connection**: keep-alive

Event types and payloads:

```
event: stage_started
data: {"stage_id": "transcribe_whisper", "item_id": "uuid", "attempt": 1}

event: stage_completed
data: {"stage_id": "transcribe_whisper", "item_id": "uuid", "duration_ms": 12345}

event: stage_failed
data: {"stage_id": "transcribe_whisper", "item_id": "uuid", "error": "timeout"}

event: stage_snoozed
data: {"stage_id": "transcribe_whisper", "item_id": "uuid", "reason": "waiting for dependency"}

event: item_status_changed
data: {"item_id": "uuid", "status": "complete"}
```

Server-side implementation:
- A Plug-based controller (not LiveView) that uses chunked transfer encoding
- On connection, subscribes to EventBus topics: `"pipeline:stage_started"`, `"pipeline:stage_completed"`, `"pipeline:stage_failed"`, `"pipeline:stage_snoozed"`, `"item:status_changed"`
- Filters events to only those matching the requested item_id
- Sends each matching event as an SSE frame
- Closes the connection when a terminal `item_status_changed` event is received (complete, incomplete, failed, cancelled)
- Sends a keepalive comment (`: keepalive\n\n`) every 15 seconds to prevent proxy/client timeouts

## Extended Existing Endpoints

### `GET /api/v1/items/:id` — richer response

The show endpoint now always includes stage execution history and artifacts, enabling the CLI stage picker, richer `show` display, and scripting.

Additional fields in the item JSON response:

```json
{
  "id": "uuid",
  "url": "...",
  "status": "...",
  "stage_executions": [
    {
      "stage": "transcribe_whisper",
      "status": "completed",
      "attempt": 1,
      "duration_ms": 12345,
      "error": null,
      "inserted_at": "2026-04-16T..."
    }
  ],
  "artifacts": [
    {
      "stage": "transcribe_whisper",
      "labels": {"type": "transcript", "format": "txt"},
      "filenames": ["transcript.txt"],
      "status": "produced"
    }
  ]
}
```

Server-side implementation:
- Preload artifacts and stage_executions in `ItemController.show/2`
- Extend `ItemJSON` to render these associations
- Query stage_executions via `Cham.JobTracking` for the item

## New CLI Commands

### `cham item delete <id-or-slug>`

Deletes an item and its archive files.

- Files are deleted by default (server-side behavior)
- `--keep-files` flag sends `?keep_files=true` to preserve archive directory
- `--yes` / `-y` flag skips confirmation prompt
- In TTY mode without `--yes`: prompts "Delete <title/url>? Files will also be deleted. [y/N]"
- In non-TTY mode: requires `--yes` (refuses to delete without explicit confirmation)

### `cham item retry <id-or-slug>`

Retries a failed or incomplete item.

- Calls `POST /api/v1/items/:id/retry`
- `--from-stage STAGE` passes `from_stage` in the request body
- `--all` flag: fetches all items with status `failed` or `incomplete`, retries each
- `--follow` flag: after retry, connects to SSE stream and shows live progress
- `--json` flag: output as JSON

### `cham item cancel <id-or-slug>`

Cancels an in-progress item.

- Calls `POST /api/v1/items/:id/cancel`
- Prints the updated item status
- `--json` flag: output as JSON

### `cham item follow <id-or-slug>`

Attaches to an item's SSE event stream and displays live pipeline progress.

- Connects to `GET /api/v1/items/:id/events` using httpx streaming
- **TTY mode**: Rich Live display with a table of stages showing name, status (with color), and duration. Updates in-place as events arrive.
- **Non-TTY / `--json` mode**: prints one JSON object per event, newline-delimited (NDJSON)
- Ctrl+C detaches cleanly; processing continues on the server
- Auto-exits when a terminal `item_status_changed` event is received
- If the item is already in a terminal status when follow starts, prints current status and exits immediately

### `cham item open <id-or-slug>`

Opens the item's original URL in the default browser.

- Fetches the item via `GET /api/v1/items/:id`
- Calls `webbrowser.open(item["url"])` from Python stdlib
- Prints the URL to stdout

### `cham item reprocess` — interactive stage picker

Enhances the existing `reprocess` command with an interactive stage picker when no `--invalidate` / `-i` flags are provided.

- Fetches item detail (which now includes stage_executions)
- Filters to completed stages only
- Presents an InquirerPy checkbox list: each row shows stage name and status
- User selects stages to invalidate
- Sends the selected stage IDs as the `invalidate` list in the reprocess request
- `--follow` flag: after reprocess, connects to SSE stream and shows live progress
- If `--invalidate` / `-i` is provided on the command line, skips the picker (existing behavior)

### `cham item add` — follow option

Enhances the existing `add` command.

- `--follow` flag: after successful submit, immediately connects to the SSE stream for the new item and renders live progress (same display as `follow`)
- Without `--follow`: existing behavior (prints item detail and exits)

## Dependencies

### CLI (pyproject.toml)

Add `InquirerPy>=0.3.4` to the dependencies list for the interactive stage picker.

### Server

No new Elixir dependencies. The SSE endpoint uses Plug's chunked response support which is built into Phoenix.

## Client Module Extensions

New methods on `ChamClient`:

- `delete_item(id_or_slug, keep_files=False)` — `DELETE /api/v1/items/:id[?keep_files=true]`
- `cancel_item(id_or_slug)` — `POST /api/v1/items/:id/cancel`
- `retry_item(id_or_slug, from_stage=None)` — `POST /api/v1/items/:id/retry`
- `stream_events(id_or_slug)` — `GET /api/v1/items/:id/events`, returns an iterator of parsed SSE events using httpx streaming

The `_request` method needs a variant for streaming responses that returns the raw httpx response for SSE consumption rather than parsing JSON.

## Error Handling

- All new endpoints follow existing patterns: 404 for not found, JSON error bodies
- Cancel returns 409 if item is already terminal
- Delete returns 204 (no body) on success
- SSE stream sends a final `item_status_changed` event before closing, so the client always knows why the stream ended
- If the SSE connection drops, the CLI prints a message and exits (no automatic reconnection — the user can re-run `follow`)
