# REST API (Minimal) — Design Spec

## Goal

Add a minimal REST API for programmatic access to Cham. Enables the CLI and scripts to submit URLs and check item status.

## Scope

Minimal subset of the full REST API design (`design-docs/rest-api.md`). No auth, no pagination cursors, no file serving, no search, no tag management, no reprocess/retry/cancel.

## Endpoints

### `GET /health`

Health check. No auth required.

**Response:** `200 OK`
```json
{"status": "ok"}
```

### `POST /api/v1/items`

Submit a URL for archiving.

**Request:**
```json
{
  "url": "https://example.com/article",
  "tags": ["ml", "research"]
}
```

`tags` is optional (defaults to `[]`).

**Response:** `202 Accepted` — full item JSON.

**Errors:**
- `409` — URL already exists
- `422` — invalid/missing URL

### `GET /api/v1/items`

List items with optional filters.

**Parameters (query string):**
- `status` — filter by status: `bootstrapping`, `processing`, `complete`, `incomplete`, `failed`
- `content_type` — filter by content type
- `tag` — filter by tag

**Response:** `200 OK`
```json
{
  "items": [{ ... }]
}
```

Returns all matching items ordered by `inserted_at` descending. No pagination for now.

### `GET /api/v1/items/:id`

Get a single item. Looks up by slug first, then by UUID.

**Response:** `200 OK` — full item JSON.

**Errors:**
- `404` — not found

## Item JSON Shape

```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "url": "https://example.com/article",
  "status": "bootstrapping",
  "title": null,
  "slug": null,
  "content_type": null,
  "tags": ["ml", "research"],
  "error_message": null,
  "metadata": {},
  "inserted_at": "2026-04-01T12:00:00Z",
  "updated_at": "2026-04-01T12:00:00Z"
}
```

Note: `bootstrap_path` and `archive_path` are internal — not exposed in the API.

## Error Format

```json
{"error": "human-readable error message"}
```

## Implementation

- `ChamWeb.ItemController` — Phoenix controller with `create`, `index`, `show` actions
- `ChamWeb.HealthController` — simple health check
- Routes in `router.ex` under a `/api/v1` pipeline with `accepts: ["json"]`
- Item JSON rendering via a view or inline `Jason.encode`
- Item lookup: `Items.get_item_by_slug_or_id/1` — tries slug first, then UUID

## Testing

- Controller tests using `ConnCase` for each endpoint
- Test successful responses, error cases (404, 409, 422)
