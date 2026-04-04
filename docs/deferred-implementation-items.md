# Deferred Implementation Items

Items scoped out of their original phase but intended for future work.

## From Phase 5 (Web UI)

- **Chat tab on item detail page** — LLM conversational interface for discussing items. Placeholder tab included in Phase 5 UI but no functionality. Needs: message history schema, streaming response handling, conversation context management.
- **Search** — Full-text/faceted search. Placeholder search box included in Phase 5 UI but non-functional. Listed as post-MVP in master plan.
- **Archive file serving endpoint** — Serve archived files (video, PDF, images) from the filesystem archive. Needs path traversal prevention and large file streaming. Placeholder UI elements shown but no file serving.
- **Media viewers** — Embedded video player, PDF viewer, image display on item detail page. Depends on file serving endpoint. Phase 5 shows text-based content and metadata only; media types show a placeholder with external link fallback.
- **Pagination** — Cursor-based pagination with "Load more" for item lists. Phase 5 loads all items (no limit). Add when archive grows large enough to need it.
- **Re-archiving existing URLs** — Currently rejects duplicate URLs. Rearchiving the same URL is a valid use case (e.g. updated content). Needs design: create new item? Reprocess existing item? Version the archive?

## From REST API

- **Authentication** — Bearer token auth via `Authorization` header. Currently no auth. Full design in `design-docs/rest-api.md`.
- **Cursor-based pagination** — `limit` + `cursor` params on list endpoints. Currently returns all items.
- **Item PATCH/DELETE** — Update tags, delete items (with optional file cleanup).
- **Reprocess/Retry/Cancel** — `POST /api/v1/items/:id/reprocess`, `retry`, `cancel` action endpoints.
- **Search endpoint** — `GET /api/v1/search` full-text search.
- **Tag management endpoints** — `GET/PATCH/DELETE /api/v1/tags`.
- **Archive endpoints** — `POST /api/v1/archive/reindex`, `GET /api/v1/archive/stats`.
- **File serving** — `GET /api/v1/items/:id/files/:filename` with range request support.
- **Slug/UUID prefix lookup** — Items lookable by slug or UUID prefix (minimum 4 chars) with disambiguation.

## From CLI

- **`cham item follow`** — Live progress display using Rich `Live` for in-progress items.
- **`cham item search`** — Full-text search (depends on search endpoint).
- **`cham item reprocess/retry/cancel`** — Pipeline control commands (depends on API endpoints).
- **`cham item delete/open`** — Delete items, open original URL in browser.
- **`cham tag list/rename/delete`** — Tag management (depends on tag API endpoints).
- **`cham archive reindex/stats`** — Archive operations (depends on archive API endpoints).
- **Non-TTY JSON output** — Auto-detect piped output and emit JSON instead of Rich tables.
- **`--json` flag** — Force JSON output in TTY mode.

## Pipeline

- **Configurable desired artifacts** — Currently hardcoded: article→[summary,tags], video→[transcript,summary,tags], document→[summary,tags]. Should be configurable via TOML config so users can control which derived artifacts are produced per content type. Design doc says: "desired artifacts come from config, determined by content type mappings."

## Architecture

- **GenServer review for filesystem operations** — Migrate Archive.ArchiveManager and Archive.FilesystemManager to GenServers. The filesystem is stateful (concurrent writes, moves, directory creation) and serializing access would prevent race conditions. Also review overall GenServer usage across the codebase to ensure stateful operations are properly serialized.
