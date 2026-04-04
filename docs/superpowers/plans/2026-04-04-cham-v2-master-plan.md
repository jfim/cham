# Cham v2 Master Implementation Plan

> **For agentic workers:** Each phase below has its own detailed implementation plan. Use superpowers:subagent-driven-development or superpowers:executing-plans to implement each phase plan task-by-task.

**Goal:** Build Cham v2 — a self-hosted personal knowledge archiving system that captures URLs, transcribes/summarizes content via an Elixir/Phoenix pipeline, and stores everything in a portable filesystem archive.

**Architecture:** Elixir/Phoenix monolith with Oban for async job processing and PostgreSQL as a rebuildable index. Python scripts (via uv) handle ML-heavy work. Plugin-based processing pipeline builds a DAG of stages per item. Filesystem archive is source of truth; DB is a rebuildable index.

**Tech Stack:** Elixir 1.17+, OTP 27+, Phoenix 1.7+ (LiveView), Oban, PostgreSQL 16+, Python 3.11+ (via uv), Docker Compose

---

## Phase Overview

Each phase builds on the previous one. Phases follow the dependency order from the design: Foundation -> Storage -> Core -> Interface. Each phase has its own detailed plan document.

### Phase 1: Project Bootstrap & Foundation

**Plan:** `2026-04-04-phase-1-project-bootstrap-and-foundation.md`

**Subsystems:** Event Bus, Config Management

**Deliverable:** A running Phoenix app with Oban configured, an internal pub/sub event bus, and a TOML-based config management system with schema validation and runtime mutation.

**Key files:**
- `lib/cham/event_bus.ex`
- `lib/cham/config/manager.ex`, `schema.ex`, `toml_encoder.ex`

---

### Phase 2: Storage Layer

**Subsystems:** Database & Index, Archive & Storage

**Deliverable:** Ecto schema for items/artifacts/stage_executions/item_messages. Filesystem Manager for atomic writes. Archive Manager for path resolution and directory layout. Metadata Manager for artifact.json parsing/merging. Reindexing support.

**Key files:**
- `lib/cham/items/item.ex` (Ecto schema)
- `lib/cham/items.ex` (context module)
- `lib/cham/archive/filesystem_manager.ex`
- `lib/cham/archive/archive_manager.ex`
- `lib/cham/archive/metadata_manager.ex`
- Migrations for items, artifacts, stage_executions, item_messages

---

### Phase 3: Core Infrastructure

**Subsystems:** LLM Integration, Script Runner, Plugin System

**Deliverable:** Provider behaviour for LLM calls with an OpenAI-compatible implementation. Script Runner for sync/async external process execution. Plugin behaviour, plugin loading, plugin registry, stage registry, conflict detection.

**Key files:**
- `lib/cham/llm/provider.ex` (behaviour)
- `lib/cham/llm/providers/openai.ex`
- `lib/cham/script_runner.ex`
- `lib/cham/plugin.ex` (behaviour)
- `lib/cham/plugin/registry.ex`
- `lib/cham/plugin/stage_registry.ex`

---

### Phase 4: Processing Pipeline & Workers

**Subsystems:** Processing Pipeline, Worker System, Job Tracking

**Deliverable:** Stage behaviour with simple/dynamic stage support. DAG construction from desired artifacts. StageWorker (Oban) that dispatches to stage modules and drives item state transitions. Job Tracking GenServer for stage execution history and ephemeral progress.

**Key files:**
- `lib/cham/pipeline/stage.ex` (behaviour)
- `lib/cham/pipeline/dag.ex`
- `lib/cham/pipeline/orchestrator.ex`
- `lib/cham/worker/stage_worker.ex`
- `lib/cham/job_tracking/tracker.ex`
- Event structs in `lib/cham/events/`

---

### Phase 5: Web UI

**Subsystems:** Web UI

**Deliverable:** LiveView dashboard with sidebar (in-progress items, content type facets, tags), search, content-type-specific item display. Item detail pages with artifact-driven content display, collapsible bottom pane (summary/transcript/metadata/chat/actions). Submit modal. Real-time updates via Event Bus. Config management UI.

**Key files:**
- `lib/cham_web/live/dashboard_live.ex`
- `lib/cham_web/live/item_detail_live.ex`
- `lib/cham_web/components/` (sidebar, item cards, etc.)

---

### Phase 6: Built-in Plugins

**Subsystems:** N/A (application-level)

**Deliverable:** Core plugins that make Cham functional out of the box:
- `generic_download_url` — fallback HTTP downloader
- `content_type_router` — routes initial downloads to content-type-specific labels
- `extract_article` — Readability-style article extraction
- `transcribe_whisper` — audio/video transcription via Whisper
- `summarize_ollama` — LLM summarization
- `auto_tag` — LLM-based tagging
- `clean_title` — title cleanup

**Key files:**
- `lib/cham/plugins/` (one module per plugin + stage modules)
- `scripts/` (Python scripts for ML-heavy stages)

---

### Phase 7: Packaging & Deployment

**Subsystems:** N/A (operations)

**Deliverable:** Multi-stage Dockerfile, Docker Compose file, runtime configuration via environment variables, auto-migration on startup.

**Key files:**
- `Dockerfile`
- `docker-compose.yml`
- `config/runtime.exs`

---

## Dependency Graph

```
Phase 1 (Foundation)
  └─> Phase 2 (Storage)
        └─> Phase 3 (Core Infrastructure)
              └─> Phase 4 (Pipeline & Workers)
                    ├─> Phase 5 (Web UI)
                    └─> Phase 6 (Built-in Plugins)
                          └─> Phase 7 (Packaging)
```

## Post-MVP Subsystems (not planned)

These are mentioned in the design docs but explicitly deferred:
- Search (advanced full-text, faceted, snippets)
- Scheduler (cron-like recurring tasks)
- Authentication & Authorization
- Subscription System (feed polling)
- Notification System
- Import/Export
- REST API
- CLI
- Observability (structured logging, telemetry)
