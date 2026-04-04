# Phase 6: Built-in Plugins — Design Spec

## Goal

Implement the core plugins that make Cham functional out of the box. Seven plugins covering the full pipeline from URL download through content extraction, transcription, summarization, tagging, and title cleanup.

## Plugin Overview

| Plugin ID | Purpose | Queue | Python? |
|---|---|---|---|
| `generic_download_url` | Fallback HTTP downloader | `:network` | No |
| `content_type_router` | Route downloads to format-specific labels | `:general` | No |
| `extract_article` | Readability-style article extraction | `:general` | Yes |
| `transcribe_whisper` | Audio/video transcription | `:gpu` | Yes |
| `summarize_ollama` | LLM summarization | `:gpu` | No |
| `auto_tag` | LLM-based tagging | `:gpu` | No |
| `clean_title` | LLM-based title cleanup | `:gpu` | No |

## Data Flow

```
input (domain:example.com)
  → generic_download_url (origin:original, type:initial_download, content_type:text/html)
  → content_type_router (origin:original, format:text, type:article)
                      OR (origin:original, format:video)
                      OR (origin:original, format:audio)
                      OR (origin:original, format:document, type:pdf)
  → extract_article (origin:original, format:text, type:content)  [articles only]
  → summarize_ollama (origin:derived, type:summary)
  → auto_tag (origin:derived, type:tags)
  → clean_title (metadata only, no artifact)
  → transcribe_whisper (origin:derived, format:text, type:transcript)  [video/audio only]
```

## File Layout

```
lib/cham/plugins/
  generic_download_url.ex
  content_type_router.ex
  extract_article.ex
  transcribe_whisper.ex
  summarize_ollama.ex
  auto_tag.ex
  clean_title.ex

scripts/
  extract_article.py
  transcribe_whisper.py
```

## Plugins

### `generic_download_url`

**Plugin ID:** `generic_download_url`
**Queue:** `:network`
**Config schema:**
- `timeout` — integer, default `300_000` (5 minutes)
- `max_body_size` — integer, default `524_288_000` (500 MB)

**Stage: `DownloadStage`**

- **Input matchers:** `[%{}]` — matches any input (wildcard fallback)
- **Output labels:** `[%{"origin" => "original", "type" => "initial_download"}]`

**Perform logic:**

1. Read URL from item metadata via `Cham.Items.get_item!/1`
2. Send HEAD request first to check `Content-Length` — if over `max_body_size`, return `{:error, "Content too large: #{size} bytes exceeds #{max_body_size} limit"}`
3. Stream HTTP GET with `Req` to working dir as `original.<ext>` (extension derived from Content-Type header or URL path, defaulting to `.bin`)
4. Save response headers as item metadata: `content_type` (from Content-Type header), `content_length`
5. Return artifact with labels including `"content_type"` from the response (e.g. `"content_type" => "text/html"`)
6. Report progress via EventBus for large downloads (based on Content-Length if known)

**Error handling:** Network timeout, HTTP 4xx/5xx, body exceeds max size — all return `{:error, reason}`.

---

### `content_type_router`

**Plugin ID:** `content_type_router`
**Queue:** `:general`
**Config schema:** none

**Stage: `RouteStage`** (dynamic stage)

- **Input matchers:** `[%{"origin" => "original", "type" => "initial_download"}]`
- **Output labels:** `[%{"origin" => "original", "format" => "routed"}]` (actual labels are dynamic)

This is a **dynamic stage** because output labels depend on the content type detected at runtime. `can_process?/1` checks for an `initial_download` artifact and returns `{:ready, [initial_download_artifact], []}`.

**Perform logic:**

1. Read `content_type` from the input artifact's labels
2. For ambiguous content types (e.g. `application/octet-stream`), fall back to magic byte inspection of the downloaded file
3. Map to format labels:
   - `text/html` → `%{"origin" => "original", "format" => "text", "type" => "article"}`
   - `application/pdf` → `%{"origin" => "original", "format" => "document", "type" => "pdf"}`
   - `video/*` → `%{"origin" => "original", "format" => "video"}`
   - `audio/*` → `%{"origin" => "original", "format" => "audio"}`
   - Unknown → `%{"origin" => "original", "format" => "unknown"}`
4. Symlink or copy the downloaded file into working dir
5. Emit item metadata: `content_type` (human-friendly: `"article"`, `"video"`, `"audio"`, `"document"`, `"unknown"`)

---

### `extract_article`

**Plugin ID:** `extract_article`
**Queue:** `:general`
**Config schema:** none

**Stage: `ExtractStage`**

- **Input matchers:** `[%{"origin" => "original", "format" => "text", "type" => "article"}]`
- **Output labels:** `[%{"origin" => "original", "format" => "text", "type" => "content", "content_type" => "text/markdown"}]`

Output is `origin:original` because this extracts the original content from its HTML wrapper, not generating new content.

**Perform logic:**

1. Read the HTML file from input artifact
2. Call `scripts/extract_article.py` via ScriptRunner, passing HTML file path and output directory
3. Script uses `trafilatura` to extract article text as markdown, plus metadata
4. Stage writes `content.md` to working dir
5. Emit item metadata: `title`, `author`, `date`, `sitename` (whatever trafilatura extracts)
6. Provenance: `trafilatura` version

---

### `transcribe_whisper`

**Plugin ID:** `transcribe_whisper`
**Queue:** `:gpu`
**Config schema:**
- `model` — string, default `"turbo"`
- `language` — string, default `nil` (auto-detect)
- `device` — string, default `"auto"`

**Stage: `TranscribeStage`**

- **Input matchers:** `[%{"origin" => "original", "format" => "video"}]` and `[%{"origin" => "original", "format" => "audio"}]` (two matchers — handles either)
- **Output labels:** `[%{"origin" => "derived", "format" => "text", "type" => "transcript", "content_type" => "text/markdown"}]`

**Perform logic:**

1. Find the media file from input artifact
2. Call `scripts/transcribe_whisper.py` via ScriptRunner, passing: file path, model, language, device, output path
3. Script uses `faster-whisper`, writes `transcript.md` with timestamps formatted as markdown
4. Script reports progress to stdout as JSON lines, parsed by ScriptRunner for progress events
5. Emit item metadata: `language`, `duration` (if not already set)
6. Provenance: model name, model version

**Snooze:** If GPU memory is insufficient, return `{:snooze, 60_000, "Insufficient GPU memory"}`.

---

### `summarize_ollama`

**Plugin ID:** `summarize_ollama`
**Queue:** `:gpu`
**Config schema:**
- `model` — string, default `"llama3.1:8b"`
- `max_input_tokens` — integer, default `8000`
- `provider` — string, default `"default"` (references a configured LLM provider)

**Stage: `SummarizeStage`**

- **Input matchers** (first match wins):
  1. `%{"origin" => "original", "format" => "text", "type" => "content"}` (extracted article text)
  2. `%{"origin" => "derived", "type" => "transcript"}` (transcribed video/audio)
- **Output labels:** `[%{"origin" => "derived", "type" => "summary", "content_type" => "text/markdown"}]`

**Perform logic:**

1. Read text content from the matched input artifact
2. Truncate to `max_input_tokens` if needed
3. Call LLM via `Cham.LLM.Provider` with a summarization prompt
4. Write `summary.md` to working dir
5. Provenance: model name, provider

**Snooze:** If Ollama is unreachable, snooze rather than fail (transient unavailability).

---

### `auto_tag`

**Plugin ID:** `auto_tag`
**Queue:** `:gpu`
**Config schema:**
- `model` — string, default `"llama3.1:8b"`
- `max_tags` — integer, default `10`
- `provider` — string, default `"default"`

**Stage: `TagStage`**

- **Input matchers** (first match wins):
  1. `%{"origin" => "original", "format" => "text", "type" => "content"}` (extracted article text)
  2. `%{"origin" => "derived", "type" => "transcript"}` (transcribed video/audio)
- **Output labels:** `[%{"origin" => "derived", "type" => "tags"}]`

**Perform logic:**

1. Read text content from matched input artifact
2. Call LLM with a tagging prompt instructing it to return a JSON list of lowercase, hyphenated tags
3. Parse response, enforce `max_tags` limit
4. Write `tags.json` to working dir
5. Emit item metadata: `tags` (the tag list, written to the item's `tags` field)
6. Provenance: model name

---

### `clean_title`

**Plugin ID:** `clean_title`
**Queue:** `:gpu`
**Config schema:**
- `model` — string, default `"llama3.1:8b"`
- `provider` — string, default `"default"`

**Stage: `CleanStage`** (dynamic stage)

- **Input matchers:** `[%{}]` — matches any input
- **Output labels:** `[]` — metadata-only, no artifacts produced

This is a **dynamic stage**. `can_process?/1` checks if a `title` exists in item metadata. Returns `:not_applicable` if no title metadata has been emitted by any prior stage, `{:ready, [], []}` if title exists.

**Perform logic:**

1. Read current title from item metadata
2. Call LLM with a prompt to clean the title (strip site names, trailing separators like " | Blog", " - SiteName", etc.)
3. If LLM returns the same title, emit unchanged (still records provenance)
4. Emit item metadata: `title` (cleaned version — overwrites via latest-timestamp-wins)
5. Provenance: model name

**No artifact files** — returns `%{artifacts: [], item_metadata: %{title: cleaned}, provenance: %{...}}`.

---

## Python Scripts

Both scripts use inline `uv` dependency declarations (`# /// script` metadata) so no separate requirements files are needed.

### `scripts/extract_article.py`

- **Dependencies:** `trafilatura`
- **Input:** HTML file path (argv[1]), output directory path (argv[2])
- **Output:** Writes `content.md` to output directory
- **Stdout:** JSON object with extracted metadata: `{"title": "...", "author": "...", "date": "...", "sitename": "..."}`
- **Exit codes:** 0 = success, non-zero = error (stderr has message)

### `scripts/transcribe_whisper.py`

- **Dependencies:** `faster-whisper`
- **Input:** media file path, output dir, model name, language (optional), device — all as positional/flag argv
- **Output:** Writes `transcript.md` to output directory
- **Stdout:** Progress lines as JSON (`{"progress": 0.45, "message": "Transcribing..."}`) followed by final JSON line with metadata (`{"language": "en", "duration": 1832}`)
- **Exit codes:** 0 = success, non-zero = error (stderr has message)

## Plugin Registration

All 7 plugins are core (compiled-in) modules discovered automatically at startup since they implement the `Cham.Plugin` behaviour. Default plugin order in `config/cham.toml`:

```toml
[plugins]
order = ["generic_download_url", "content_type_router", "extract_article", "transcribe_whisper", "summarize_ollama", "auto_tag", "clean_title"]
```

## Testing Strategy

- **Unit tests** for each stage: mock ScriptRunner responses, mock LLM provider, mock HTTP with `Req.Test` — no network, no GPU required
- **Integration tests** tagged `@moduletag :integration` for stages calling real external services (Ollama, Whisper, network downloads)
- Pattern follows existing test plugins in `test/support/test_plugins.ex`

## Dependencies

- `Cham.Plugin` behaviour — plugin registration
- `Cham.Stage` behaviour — stage execution interface
- `Cham.LLM.Provider` — LLM calls for summarize, auto_tag, clean_title
- `Cham.ScriptRunner` — Python script execution
- `Cham.Items` — item/artifact queries
- `Cham.Archive.ArchiveManager` — working directory creation
- `Cham.EventBus` — progress reporting
- `Req` — HTTP client for downloads
