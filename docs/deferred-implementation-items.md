# Deferred Implementation Items

Items scoped out of their original phase but intended for future work.

## From Phase 5 (Web UI)

- **Chat tab on item detail page** — LLM conversational interface for discussing items. Placeholder tab included in Phase 5 UI but no functionality. Needs: message history schema, streaming response handling, conversation context management.
- **Search** — Full-text/faceted search. Placeholder search box included in Phase 5 UI but non-functional. Listed as post-MVP in master plan.
- **Archive file serving endpoint** — Serve archived files (video, PDF, images) from the filesystem archive. Needs path traversal prevention and large file streaming. Placeholder UI elements shown but no file serving.
- **Media viewers** — Embedded video player, PDF viewer, image display on item detail page. Depends on file serving endpoint. Phase 5 shows text-based content and metadata only; media types show a placeholder with external link fallback.
- **Pagination** — Cursor-based pagination with "Load more" for item lists. Phase 5 loads all items (no limit). Add when archive grows large enough to need it.
- **Re-archiving existing URLs** — Currently rejects duplicate URLs. Rearchiving the same URL is a valid use case (e.g. updated content). Needs design: create new item? Reprocess existing item? Version the archive?

## Architecture

- **GenServer review for filesystem operations** — Migrate Archive.ArchiveManager and Archive.FilesystemManager to GenServers. The filesystem is stateful (concurrent writes, moves, directory creation) and serializing access would prevent race conditions. Also review overall GenServer usage across the codebase to ensure stateful operations are properly serialized.
