# Download Images Plugin — Design

**Date:** 2026-04-17
**Status:** Proposed

## Problem

Article content extracted by `extract_article` retains remote image URLs (`![](https://cdn.example.com/…)`). The archive is not self-contained: if a host 404s, moves, or blocks referrers, images disappear from archived articles. The rest of Cham's design treats the filesystem as source of truth — inline images are the one large gap.

## Goal

Produce a derived markdown artifact per article in which every image reference points to a locally-stored file, and store those files so they survive DB rebuilds.

Out of scope:
- Rehosting images in LLM-generated artifacts (summaries, etc.). Adding later is trivial.
- Snapshotting images at initial HTML-fetch time. The `extract_article → download_images` chain is sufficient for now.

## Architecture

A new plugin `download_images` with a single stage `Cham.Plugins.DownloadImages.Stage`.

- **Input matcher:** `%{"origin" => "original", "format" => "text", "type" => "content", "content_type" => "text/markdown"}` — i.e. the output of `extract_article`.
- **Output labels:** `%{"origin" => "derived", "format" => "text", "type" => "content", "content_type" => "text/markdown", "provider" => "download_images"}`
- **Artifact contents:** rewritten `content.md` alongside downloaded `img_<md5>.<ext>` files, all in one artifact directory.

The implementation is a Python script invoked via `Cham.ScriptRunner` (following the pattern of `extract_article`, `extract_pdf`, `transcribe_whisper`). Python gets us `httpx` / `requests` for HTTP with timeouts and redirects, and a regex over markdown is simpler than in Elixir.

The Elixir stage:
1. Loads `item.url` (for relative-URL resolution).
2. Invokes the script with the input markdown path, the item's base URL, the item id, and the working directory.
3. Wraps the script's output into the artifact record.

The script:
1. Parses `content.md` for `![alt](url)` references. Ordinary markdown syntax only — no HTML `<img>` tags, no reference-style links. (Trafilatura emits the `![]()` form; if that assumption ever breaks we extend the regex.)
2. For each reference:
   - `key` = URL as written in the markdown (no normalization).
   - `ext` = extension from the path segment of `key`, before any `?query`. If absent, fall back to the response `Content-Type` at download time (e.g. `image/png` → `.png`).
   - `filename` = `img_<md5(key)>.<ext>`.
   - `fetch_url` = `urljoin(base_url, key)` — absolute URLs pass through unchanged, relative URLs resolve against the item's URL.
   - Download with a 10s connect / 30s read timeout, up to 10 MB per image, following redirects. On success, write to `<working_dir>/<filename>`. On failure, leave the original remote URL in place and record the failure.
3. Rewrite the markdown: successful downloads → `![alt](/api/v1/items/<item_id>/files/<filename>)`; failures → unchanged.
4. Write the rewritten file to `<working_dir>/content.md`.
5. Emit a JSON summary on stdout: `{"succeeded": N, "failed": M, "skipped_duplicate": K}`.

The script runs with `uv`, dependencies declared inline (PEP 723) — matching existing scripts.

## Data Flow

```
generic_download_url  →  (HTML)
        ↓
extract_article       →  origin=original, type=content (content.md with remote image URLs)
        ↓
download_images       →  origin=derived,  type=content (content.md + img_*.ext)
```

## Filename Invariant

Given any `![alt](url)` in the original `content.md`, the corresponding local file is deterministically `img_<md5(url)>.<ext>`. No side-channel metadata needed to reverse-map. This means:

- Re-running the stage is idempotent in name-space — previously-downloaded files would be regenerated with identical names. (We don't need explicit caching; the stage re-downloads on every run. Fine for current scale.)
- A future debugging tool can walk the original markdown and list expected files without touching DB state.

## UI Change

`lib/cham_web/live/item_detail_live.ex:193-199` currently hard-codes `origin => "original"` when resolving article content. Change `resolve_primary_content/3` so article resolution prefers `origin=derived, type=content` and falls back to `origin=original, type=content` when no derived artifact exists.

This preserves behavior for:
- Old items that haven't been reprocessed.
- Items where `download_images` hasn't run yet (still processing).
- Environments where the plugin is disabled.

No schema change, no ordering logic beyond "derived if available, else original."

## Error Handling

- **Per-image failure** (404, timeout, non-image content-type, size cap exceeded, connection refused): log to provenance counters, keep the remote URL in the rewritten markdown. The article is never worse than it was before the stage ran.
- **All-images-failed:** still a success. The derived artifact contains `content.md` with zero local images (all remote URLs preserved). The UI will render from it and the user sees the same broken-image behavior as without the stage.
- **No images in markdown:** still emit a derived artifact containing `content.md` verbatim. Keeps the "derived is canonical" invariant simple at the cost of one extra file copy per article.
- **Script crash / timeout / non-zero exit:** stage returns `{:error, reason}`; Oban retries per `max_attempts`. Following the convention in `extract_article.ex`.

Provenance map on the artifact:
```elixir
%{
  "tool" => "download_images",
  "succeeded" => 7,
  "failed" => 1,
  "failures" => [%{"url" => "https://…", "reason" => "timeout"}]
}
```

## Testing

Unit (no network):
- Filename derivation: absolute URL, relative URL, URL with query string, URL with no extension.
- Markdown rewriter: replaces only successful downloads; preserves failures.
- URL extraction: standard `![]()`; nested brackets in alt text; multiple images on one line.

Integration (`@moduletag :integration`, requires network):
- End-to-end against a small public image; verifies artifact files on disk and rewritten markdown content.
- A fabricated 404 URL: verifies fallback to remote URL and provenance counter.

## Configuration

Initial config schema is empty — sensible defaults hard-coded. If it later grows:
- `max_image_bytes` (default 10_000_000)
- `connect_timeout_ms`, `read_timeout_ms`
- `follow_redirects` (default true)

Register at `plugins.download_images` if/when config is added.

## Migration

Existing items won't have the derived artifact. Users can reprocess via the Actions tab → "Rerun `download_images`" once the plugin is registered. No automatic backfill — item count is manageable and reprocessing is cheap.
