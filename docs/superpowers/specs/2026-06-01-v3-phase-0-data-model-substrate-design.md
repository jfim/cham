# v3 Phase 0 — Data-Model Substrate — Design

**Date:** 2026-06-01
**Status:** approved (brainstormed in dialogue → ready for implementation plan)
**Builds on:**
- [v3 data model](2026-05-30-v3-data-model-design.md) — conceptual entities & identity
- [v3 physical layout](2026-05-30-v3-physical-layout-design.md) — §6 schema, §2 on-disk tree, §3 lifecycle, §7 edge resolution
- [v3 ingestion reconciliation & sequencing](2026-06-01-v3-ingestion-reconciliation-and-sequencing.md) — Phase 0 in the build sequence; apply its Part B reconciliations

This is **Phase 0** of the v3 ingestion rework. It stands up the storage substrate
(Postgres schema, on-disk layout, URL identity) and the primitive contexts, and tears
out the v2 ingestion layer the schema change breaks.

## 1. Goal & End State

Establish the v3 data-model substrate that every later phase reads and writes, with
nothing above it yet (no `plan`, no executor, no capture).

**End state after Phase 0:**
- The repo compiles and `mix test` is green on the new units.
- Infra is intact: config (TOML `Config.Manager`/`Schema`), event bus, Oban wiring,
  LiveView shell, smoke-test harness.
- There is **no end-to-end ingestion pipeline** — that is rebuilt in Phases 2–7. This
  is expected per the build strategy (in-place rewrite on a branch, non-runnable until
  the Phase 5 cutover).

## 2. Scope

### In scope
- The v3 Postgres schema: six tables + a fresh migration set.
- `Cham.Archive.Layout` — on-disk path construction, create-in-archive, atomic
  `artifact.json` write, re-slugify rename.
- `Cham.Identity` — URL normalization (versioned, in code), hashing, hash-set lookup.
- Ecto schemas + **primitive** context functions (building blocks only; the
  orchestrated submit flow is Phase 3).
- Teardown of the v2 ingestion layer broken by the schema change.

### Out of scope (owned elsewhere)
- The `facts` projection and the durable outcome-record shape (Phase 1/2).
- The transactional submit path + unique-constraint dedup-fallback + enqueue (Phase 3).
- Reindex (Phase 2).
- Future normalization-version features: `www.` stripping, IDN→punycode, query-param
  reordering.
- `pgvector`/embeddings, per-user data split, typed-artifact on-disk contracts
  (post-v3-core).

## 3. Postgres Schema

Realizes physical-layout §6 with the reconciliation-doc Part B amendments folded in.
`url_hash` is stored as `text` (lowercase hex).

### Reshaped: `items`

Drops v2's `url` and `bootstrap_path`. Identity moves to `url_identities`; there is no
staging path.

| Column | Type | Notes |
|---|---|---|
| `id` | uuid | PK. First 8 hex = the slug `shorthash`. |
| `slug` | text | `ingest-<hash>` then `<title-slug>-<hash>`. |
| `title` | text, null | Null until first title-bearing extraction. |
| `status` | text | `bootstrapping`/`extracting`/`processing`/`complete`/`incomplete`/`failed`. Maintained projection of the active frontier; terminal tiers rebuildable from artifacts by reindex, in-flight states re-driven by `plan`. |
| `archive_path` | text | Relative item dir (`YYYY/MM/DD/<slug>`). **Unique.** |
| `first_captured_at` | utc_datetime | Drives date sharding; immutable. |
| `tags` | jsonb | User + auto tags. |
| `metadata` | jsonb | Merged item-level metadata. |
| `search_vector` | tsvector | Full-text index. |
| `inserted_at`/`updated_at` | utc_datetime | |

**No `content_type` column** (overrides physical-layout §6). An item has a *set* of
component types, not a primary one; type filtering ("show me all videos") is a query
over `components` (an item is a video iff its latest snapshot has a `video` component).
If that join becomes a hot path we denormalize a `content_types` **array** maintained by
the projection — deferred (YAGNI).

Indexes: unique(`archive_path`), btree(`status`), btree(`first_captured_at`),
GIN(`tags`), GIN(`search_vector`). Id-prefix lookup (`cham item view <hash>`) matches on
`id` (carry over v2 `lookup_by_id_prefix`).

### New: `url_identities` (keystone resolution table)

| Column | Type | Notes |
|---|---|---|
| `id` | uuid | PK |
| `item_id` | uuid | FK → items (delete_all) |
| `url_hash` | text | SHA-256 hex of the normalized URL. **Unique** (two items never share a hash). |
| `normalized_url` | text | The normalized URL (display/debug). |
| `role` | text | `submitted` / `redirect_alias`. |
| `inserted_at` | utc_datetime | |

Indexes: unique(`url_hash`), btree(`item_id`). Lookup = single index hit on `url_hash`.

### New: `snapshots`

| Column | Type | Notes |
|---|---|---|
| `id` | uuid | PK |
| `item_id` | uuid | FK → items (delete_all) |
| `captured_at` | utc_datetime | |
| `provenance` | jsonb | How this capture was triggered: `{kind, actor, ref, agent}`. Per-snapshot (each capture has its own origin). Written at snapshot creation. |
| `snapshot_path` | text | Relative (`snapshots/<ts>/`) |
| `inserted_at` | utc_datetime | |

Indexes: btree(`item_id`), btree(`captured_at`).

**No `status` column** (overrides physical-layout §6). Lifecycle is tracked at the
item level (`items.status`); every consumer (UI list/detail, CLI/REST filters, stats,
restart reconciliation) reads it per-item, and `plan` does not read it at all (status is
an output projection, not a `plan` input). Per-snapshot state — "complete item, newer
capture in progress" or a snapshot-history badge — is derivable (item status non-terminal
+ a prior snapshot with produced artifacts; a snapshot's outcome from its own artifacts).
Re-add a stored per-snapshot status later only if a real consumer appears (a cheap
migration).

### New: `components`

| Column | Type | Notes |
|---|---|---|
| `id` | uuid | PK |
| `snapshot_id` | uuid | FK → snapshots (delete_all) |
| `content_type` | text | `article`/`video`/`page`/… |
| `inserted_at` | utc_datetime | |

Unique(`snapshot_id`, `content_type`); btree(`snapshot_id`).

### Reshaped: `artifacts`

Re-keyed from `item_id` to the snapshot/component hierarchy; gains `category` and
`version`.

| Column | Type | Notes |
|---|---|---|
| `id` | uuid | PK |
| `snapshot_id` | uuid | FK → snapshots (delete_all). Always set. |
| `component_id` | uuid, null | FK → components (delete_all). Null for `capture` (snapshot-level). |
| `category` | text | `capture` / `extracted` / `derived` |
| `stage` | text | Plugin id |
| `labels` | jsonb | Label map |
| `filenames` | text[] | Output filenames (a string list; `text[]` not jsonb — greppable, matches v2) |
| `path` | text | Relative stage dir |
| `status` | text | `produced` / `failed` / `not_applicable` |
| `version` | integer | Stage version (reprocess invalidation) |
| `started_at`/`ended_at` | utc_datetime | |

Indexes: btree(`snapshot_id`), btree(`component_id`), GIN(`labels`), btree(`status`).

### New: `edges`

| Column | Type | Notes |
|---|---|---|
| `id` | uuid | PK |
| `source_item_id` | uuid | FK → items (delete_all) |
| `edge_type` | text | `embed` / `linked` / `mirror` |
| `target_url_hash` | text | What extraction emitted (canonical). |
| `target_item_id` | uuid, null | Cached hash→item resolution; null = dangling. on_delete: nilify. |
| `provenance` | text | `extractor` / `user` |
| `inserted_at` | utc_datetime | |

Indexes: btree(`source_item_id`), btree(`target_url_hash`), btree(`target_item_id`).

### Kept unchanged

`stage_executions`, `item_messages`, `subscriptions`, oban tables. Not rebuilt by
reindex. Their FKs to `items(id)` survive (the `items` PK is unchanged); the migration
re-establishes them against the recreated table.

### Migration strategy

A **fresh v3 migration set**: drop v2 `items` and `artifacts`, create the v3 six,
re-establish the kept tables' FKs to the new `items`. Dev databases reset; this is
acceptable because the archive is the source of truth and the index is rebuildable
(reindex, Phase 2). Exact drop/recreate ordering vs. dependent FKs is an implementation
detail for the plan.

## 4. On-Disk Layout — `Cham.Archive.Layout`

Replaces v2's `ArchiveManager` (bootstrap/move) and `FilesystemManager`. Realizes
physical-layout §2–§3.

- **Path construction** (pure): item dir `archive/YYYY/MM/DD/<slug>/`; snapshot
  `snapshots/<ts>/`; `capture/`; component `components/<type>/`; stage
  `stages/<stage_id>-<ts>/`; input record `input-<ts>/`. `<ts>` is ISO8601-basic
  (`YYYYMMDDTHHMMSSZ`).
- **`shorthash/1`** = first 8 hex chars of the item uuid.
- **`slugify/1`** = title → slug (carried from v2 orchestrator's `slugify`, **title
  only — no `slugify(url)` floor**).
- **`create_item_dir/2`** = mkdir `archive/YYYY/MM/DD/ingest-<shorthash>/` (date = now).
- **`atomic_write/2`** = temp file + rename, so `artifact.json` is complete-or-absent
  (carried from `FilesystemManager.atomic_write`).
- **`re_slugify/2`** = rename leaf `ingest-<shorthash>` → `<slugify(title)>-<shorthash>`
  within the same date dir (atomic, same-filesystem); returns the new relative
  `archive_path`. Caller updates the DB rows (see §5; crash-safety per physical-layout
  §3: rename first, then DB).
- `archive_root` from the existing `Application.get_env(:cham, :archive_root, ".")`.

## 5. Identity — `Cham.Identity`

Realizes data-model §3/§3.1; rules live in code with an explicit version (per the
approved decision — a versioned, reviewed change, never a silent config edit that
retroactively breaks hashes).

- **`@normalization_version 1`** — stamped alongside any persisted identity for future
  migrations.
- **`normalize/1`** (version 1 rules):
  - lowercase scheme; lowercase host; strip trailing host dot;
  - drop the default port (80 for http, 443 for https);
  - empty path → `/`; **no trailing-slash stripping** on non-root paths;
  - **strip the versioned tracking-param denylist** (below); **keep all remaining
    query params in their original order** (no reordering in v1);
  - drop the fragment.
  - **Denylist v1 (pure trackers only):** `utm_source`, `utm_medium`, `utm_campaign`,
    `utm_term`, `utm_content`, `utm_id`, `fbclid`, `gclid`, `gbraid`, `wbraid`,
    `msclkid`, `mc_eid`, `mc_cid`, `igshid`, `_hsenc`, `_hsmi`. Ambiguous params that
    can be load-bearing (e.g. `ref`) are **excluded**.
- **`hash/1`** = SHA-256 of the normalized URL (UTF-8), lowercase hex. The
  `unique(url_hash)` constraint depends on collision resistance.
- **`lookup_item_by_url/1`** = `normalize → hash → Repo.get_by(UrlIdentity, url_hash:)`
  → `item_id`, or `nil`. Single index hit.

Deferred to future normalization versions: `www.` stripping, IDN→punycode,
query-param reordering.

## 6. Ecto Schemas + Primitive Contexts

Schemas: `Item`, `UrlIdentity`, `Snapshot`, `Component`, `Artifact`, `Edge` (each with a
changeset enforcing the constraints above).

Phase 0 ships the **building-block functions only** — the orchestrated, transactional
submit path with dedup-fallback and capture enqueue is Phase 3:

- **`create_item_with_identity(submitted_url, provenance)`** — in one transaction
  inserts the `items` row (`status: bootstrapping`, `slug: ingest-<shorthash>`,
  `archive_path`, `first_captured_at`), the `url_identities(role: submitted)` row, and
  the **first `snapshots` row** (creation-time `captured_at`, the given `provenance`);
  then creates the on-disk item dir and writes that snapshot's input record
  (`{provenance, submitted_url, submitted_hash}`). The capture stage (Phase 4) later
  runs inside this same first snapshot (ingestion-completion §6.4). Surfaces a
  `unique(url_hash)` violation as `{:error, :exists}` (Phase 3 turns that into
  resolve-to-existing-item + enqueue).
- **`lookup_item_by_url/1`** (§5).
- **`add_redirect_aliases(item, normalized_urls)`** — inserts
  `url_identities(role: redirect_alias)` rows (used by the capture stage in Phase 4).
- **`write_input_record(item, snapshot, provenance)`** — atomic write of
  `snapshots/<ts>/input-<ts>/artifact.json`.
- **`re_slugify(item, title)`** — calls `Layout.re_slugify`, then updates `items.slug`
  and `items.archive_path` (rename-first, DB-second).
- Thin insert helpers: `create_snapshot/2`, `create_component/2`, `record_artifact/2`
  (consumed by the Phase 2 projection; the **write** primitives live here).

These replace the v2 `Cham.Items` create/lookup surface; v2 read functions tied to
removed columns/shape are removed (§7).

## 7. v2 Teardown

The schema change breaks the v2 ingestion layer at compile time. Phase 0 removes it so
the repo compiles and tests run, keeping the infra.

**Remove:**
- `lib/cham/pipeline.ex`, `lib/cham/pipeline/orchestrator.ex`,
  `lib/cham/pipeline/stage_worker.ex`, `ArchiveManager`, `FilesystemManager`.
- All `lib/cham/plugins/*` (rebuilt as v3 stages in Phases 4–7).
- v2-coupled `Cham.Items` read functions (artifact reads keyed by `item_id`, the
  thumbnail/title-override queries, `read_primary_markdown`, the `url`/`bootstrap_path`
  references) and the subscriptions URL-join (`s.source_url == i.url`).
- Item list/detail LiveViews and CLI commands that read removed columns/shape.

**Keep:** config (`Config.Manager`/`Schema`/`TomlEncoder`), event bus, Oban wiring,
LiveView shell + router, `ScriptRunner`, subscriptions table/schema, smoke-test harness
(assertions rewritten in Phase 5).

**Placeholder rule:** where a *kept* module references removed code, reduce it to a
compiling placeholder with a comment naming the phase that rebuilds it — do not leave
dead logic.

## 8. Testing

- **Identity (pure unit):** `normalize/1` is deterministic and version-stamped; each
  denylisted param is stripped and each non-denylisted param + its order is preserved;
  default-port drop, fragment drop, empty-path→`/`; `hash/1` round-trips and is stable.
- **Layout (unit, tmp dir):** path construction; `atomic_write` is complete-or-absent
  (no partial file on simulated mid-write failure); `re_slugify` renames the leaf within
  the same date dir and returns the new `archive_path`.
- **Schema/contexts (integration, real DB):** each entity round-trips;
  `unique(url_hash)` trips on a duplicate (`{:error, :exists}`); `lookup_item_by_url`
  hits an inserted identity and misses an unknown URL; `create_item_with_identity`
  writes the `items` + `url_identities` rows, the on-disk dir, and the input record;
  `re_slugify` updates `slug` + `archive_path` to match the renamed dir.

## 9. Open Questions (non-blocking; resolve in the owning phase)

- **Exact `<ts>` precision / collision handling** for sub-second multiple captures
  (Phase 4 may need millisecond ts or a discriminator).
- **`provenance` jsonb shape** beyond `{kind, actor, ref, agent}` — finalized when the
  submit path (Phase 3) and discovery (Phase 5) land.
- **Multiple same-type components** index-discriminator (data-model §10) — only matters
  once a real case appears (Phase 5).
