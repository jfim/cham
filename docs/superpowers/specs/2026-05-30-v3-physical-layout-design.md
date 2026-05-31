# v3 Physical Layout — On-Disk Structure & Postgres Schema — Design

**Date:** 2026-05-30
**Status:** Design / spec. Physical realization of the v3 core data model.
Companion to:
- `2026-05-30-v3-data-model-design.md` — the conceptual data model (items/
  snapshots/components/artifacts/edges/identity/provenance). This spec is its
  deferred §9 "physical layout."
- `2026-05-29-ingestion-rework-design.md` — the control plane. This spec amends
  it (§8): the physical archive move and the archive handshake change.

## 1. Motivation and Scope

The data-model spec finalized the conceptual entities but explicitly deferred how
they are stored: the archive directory layout and the Postgres schema (how
snapshots, components, edges, URL identities, and provenance are written to disk
and rebuilt into the index). This spec settles that.

Two principles inherited from v2 and kept:

- **Filesystem archive is the source of truth; Postgres is a rebuildable index.**
  Everything in the DB (except chat history and in-flight job state) is
  reconstructable by scanning the archive.
- **Derive-from-stages, no manifests.** An item's state is derived by scanning
  the `artifact.json` of each stage execution (latest-timestamp-wins). v3 adds
  graph data (identity, edges, provenance) but introduces **no new on-disk file
  types** — each piece of graph data is emitted into the `artifact.json` of the
  stage that naturally owns it (§5). The graph itself lives only in the
  rebuildable DB index.

### In scope

- The archive directory tree for items → snapshots → components → stage outputs.
- Item lifecycle on disk: create-in-archive, temporary slug, re-slugify rename
  (replacing v2's bootstrap-staging-then-move).
- Where each piece of graph data (identity hashes, provenance, edges) is emitted
  on disk.
- The Postgres schema: tables, columns, indexes, constraints.
- Edge resolution (hash → item) and dangling edges.
- Reindex (rebuild the index from the archive).
- Amendments to the ingestion-rework spec these decisions force.
- A low-fidelity v2→v3 converter (secondary deliverable).

### Out of scope (own specs / deferred)

- Per-user data split (`users/<user_id>/` subtree).
- Typed-artifact on-disk contracts (per-type manifests, embeddings format,
  `pgvector` mirror).
- Display transforms (link rewriting, "Cham it").
- The detailed extractor↔executor↔enqueue discovery protocol (control plane).
- The exact URL-normalization denylist (data-model spec open question).

## 2. On-Disk Layout

```
archive/YYYY/MM/DD/<slug>/                  # YYYY/MM/DD = first-capture date
  snapshots/
    20260402T143000Z/                       # one snapshot = one top-level capture; immutable; named by capture ts
      input-20260402T143000Z/
        artifact.json                       # snapshot-level provenance {kind,actor,ref,agent,captured_at}
      capture/
        stages/
          passe_partout-20260402T143005Z/
            capture.warc.gz                 # raw bytes + self-contained assets (passe-partout WARC)
            artifact.json                   # category=capture; emits redirect chain + URL hashes
            passe_partout.log
      components/
        article/                            # component; dir name = content type (one per type per snapshot)
          stages/
            extract_article-20260402T143040Z/   # category=extracted (the component content); emits edges
              article.md  artifact.json  extract_article.log
            summarize-20260402T144530Z/          # category=derived
              summary.md  artifact.json  summarize.log
        comments/
          stages/ ...
    20260815T100000Z/                       # a re-capture months later = sibling snapshot, same item dir
      ...
```

### Rules

- **Date sharding** is the item's first-capture date (`first_captured_at`). It
  never changes; later snapshots stay under the original item dir so an item
  remains one navigable directory.
- **Snapshot is the unit that nests.** Every top-level capture is a new
  `snapshots/<capture-ts>/`. `ls snapshots/` answers "how many times have I
  captured this." Snapshots are immutable.
- **Capture is snapshot-level; components are extracted from it.** Raw WARC lives
  in `snapshots/<ts>/capture/`. Components only exist once an extract stage
  classifies content, so there is no "decide the component dir before extraction"
  problem.
- **One component per content type per snapshot** (`article`, `video`,
  `document`, `audio`, `podcast`, `pdf`, `comments`, …). Multiple components of
  the *same* type in one snapshot is not supported now; relax later if a real
  case appears.
- **Stage directories are `stages/<stage_id>-<ts>/`** where `<stage_id>` is the
  plugin id and `<ts>` is ISO8601 of when the stage execution began. This unifies
  v2's `processing/<plugin>-<ts>/` with the ingestion spec's per-stage log file
  (`<stage>.log` lives in the stage dir). Reprocessing creates a new `<ts>` dir;
  latest-timestamp-wins; old dirs are preserved (history), as in v2.
- **`artifact.json` per stage dir** carries the stage's outcome, artifact list
  (labels, filenames), category, version, and the graph data that stage emits
  (§5). Written atomically (temp file + rename) so it is complete or absent.
- **Derived artifacts are per-component** — they live in `components/<type>/`.
  There is no snapshot-level or item-level `derived/` dir. A cross-component
  summary is a future *reprocessing* decision, not a layout change.

### Slug

- `shorthash` = the first 8 hex characters of the item's uuid. It is **constant
  for the item's whole life** and is baked into the slug so the archive path is
  CLI-addressable: `find … | grep foo` surfaces a path whose suffix is a handle
  for `cham item view <shorthash>` (resolves by id-prefix) without reading any
  metadata.
- **Temporary slug** (before a title exists): `ingest-<shorthash>`. All in-flight
  items cluster under `ingest-*` in a listing.
- **Final slug** (after first extraction yields a title):
  `<slugify(title)>-<shorthash>`. Re-slugify only prepends the title; the hash is
  unchanged, so `cham item view <shorthash>` works at every lifecycle stage.
- **Uniqueness:** `archive_path` (= `YYYY/MM/DD/<slug>`) is the unique key, not
  `slug`. The `shorthash` suffix makes natural collisions effectively impossible;
  a user may rename the title part away (e.g. `foo-a1b2c3d4` → `foo`) and it is
  harmless as long as the new `archive_path` is free.
- An item that captures but never classifies (no title — the ingestion spec's
  "got bytes, unclassified, keep browseable" tier) **retains its `ingest-<shorthash>`
  name** permanently. Still addressable; no `slugify(url)` fallback needed.

## 3. Item Lifecycle on Disk

v2 staged items in `tmp/bootstrap/<id>/` and **physically moved** the tree to its
permanent slug-named location once capture completed. v3 **eliminates staging and
the move.** An item is created directly in the archive under a temporary slug and
"promoted" by a same-directory **rename** once a title exists.

1. **Submit URL** → insert `items` row (`status=bootstrapping`); create
   `archive/YYYY/MM/DD/ingest-<shorthash>/` (date = now).
2. **Capture** (bootstrap phase) runs in `…/snapshots/<ts>/capture/stages/`.
   The capture stage emits the redirect chain + URL hashes into its
   `artifact.json`; the executor writes provenance into the snapshot's
   `input-<ts>/` record. `status=bootstrapping`.
3. **First extraction** (`status=extracting`) runs in
   `…/components/<type>/stages/` and produces the first component(s) and a title.
4. **Re-slugify** (executor side-effect on the first title): rename the leaf
   `ingest-<shorthash>` → `<slugify(title)>-<shorthash>` within the same date dir
   (atomic, same-filesystem); update `items.slug` and `items.archive_path`.
   `status=processing`.
5. **Process** stages (transcribe, summarize, embeddings, …) run **in place** in
   the archive. `status` → `complete` / `incomplete` on terminal.
6. **Re-capture later:** because the slug is already known, a new
   `snapshots/<new-ts>/` is created **directly in place** — no temp slug, no
   rename. Only an item's *first* snapshot ever carries the `ingest-` phase.

**Crash safety of re-slugify:** rename first, then update the DB rows. A crash in
between leaves disk and DB momentarily disagreeing on the leaf name; reindex /
reconciliation detects and repairs it (the archive is the source of truth). No
cross-device move, no partial tree copy — the failure surface is one atomic
rename.

A future **explicit `re-slugify` op** (rename dir + update `slug`/`archive_path`)
lets a user rename an item deliberately; it is the same mechanism as step 4.

## 4. Status States

`bootstrapping` → `extracting` → `processing` → `complete` / `incomplete` /
`failed`.

Status is a **projection** of which ingestion phase holds the active frontier:
`bootstrapping` = capture phase; `extracting` = first extraction running
(pre-slug); `processing` = derived-artifact stages; terminal states per the
ingestion spec's failure tiers (`failed` = couldn't get bytes; `incomplete` = got
bytes but a downstream stage failed; `complete` = all desired artifacts present).

## 5. Where Graph Data Is Emitted (Derive-from-Stages)

No manifests; each piece of graph data rides the stage that owns it, so reindex
reconstructs it by scanning:

- **URL identity hashes** → the **capture stage** (passe-partout) emits the full
  redirect chain and the normalized-URL hashes into its `artifact.json`. The
  submitted URL is `role=submitted`; redirect-chain URLs are
  `role=redirect_alias`.
- **Provenance** → written by the executor into the **snapshot `input-<ts>/`
  record** at snapshot creation (it is known then): `{kind, actor, ref, agent,
  captured_at}`. Snapshot-level, since a first web capture and a later timed or
  user-invoked re-capture each carry their own trigger. The input record also
  stores the **full item id** (the slug carries only the 8-char `shorthash`), so
  reindex can recover it without ambiguity.
- **Edges** → an **extract stage** emits `{edge_type, target_url}` (e.g.
  `embeds`/`refers_to` + normalized URL) into its `artifact.json`, on the
  **source** item. Resolution to a concrete `target_item_id` is a runtime DB
  lookup (§7), not stored on disk.

There is no genuinely "item-level, no stage to live in" data: identity rides
capture, provenance rides input, edges ride extract.

## 6. Postgres Schema

The DB is the rebuildable graph index. Tables (new/changed unless noted):

### `items`

| Column | Type | Notes |
|---|---|---|
| `id` | uuid | PK. First 8 hex = the slug `shorthash`. |
| `slug` | text | `ingest-<hash>` then `<title-slug>-<hash>`. |
| `title` | text, null | Null until first extraction. |
| `status` | text | `bootstrapping`/`extracting`/`processing`/`complete`/`incomplete`/`failed`. |
| `content_type` | text, null | **Denormalized convenience**: primary component type of the latest snapshot, for UI filtering. Derived. |
| `archive_path` | text | Relative item dir (`YYYY/MM/DD/<slug>`). **Unique.** |
| `first_captured_at` | utc_datetime | Drives date sharding; immutable. |
| `tags` | jsonb | User + auto tags. |
| `metadata` | jsonb | Merged item-level metadata. |
| `search_vector` | tsvector | Full-text index. |
| `inserted_at`/`updated_at` | utc_datetime | |

There is **no `url` column** (identity moved to `url_identities`) and **no
`bootstrap_path`** (no staging). Indexes: unique(`archive_path`), btree(`status`),
btree(`content_type`), btree(`first_captured_at`), GIN(`tags`),
GIN(`search_vector`). Id-prefix lookup (`cham item view <hash>`) matches on `id`.

### `url_identities` — the keystone resolution table

The `hashed_normalized_url → item_id` index; N rows per item form the identity
hash set.

| Column | Type | Notes |
|---|---|---|
| `id` | uuid | PK |
| `item_id` | uuid | FK → items (on_delete: delete_all) |
| `url_hash` | text | Hash of the normalized URL. **Unique** (two items never share a hash). |
| `normalized_url` | text | The normalized URL (for display/debug). |
| `role` | text | `submitted` / `redirect_alias`. (`canonical` dropped — a page's self-declared canonical can be broken and poison identity.) |
| `inserted_at` | utc_datetime | |

Indexes: unique(`url_hash`), btree(`item_id`). **Lookup = single index hit on
`url_hash`.**

### `snapshots`

| Column | Type | Notes |
|---|---|---|
| `id` | uuid | PK |
| `item_id` | uuid | FK → items (delete_all) |
| `captured_at` | utc_datetime | |
| `provenance` | jsonb | `{kind, actor, ref, agent}` |
| `status` | text | Per-snapshot lifecycle |
| `snapshot_path` | text | Relative (`snapshots/<ts>/`) |
| `inserted_at` | utc_datetime | |

Indexes: btree(`item_id`), btree(`captured_at`).

### `components`

| Column | Type | Notes |
|---|---|---|
| `id` | uuid | PK |
| `snapshot_id` | uuid | FK → snapshots (delete_all) |
| `content_type` | text | `article`/`video`/… |
| `inserted_at` | utc_datetime | |

Unique(`snapshot_id`, `content_type`) — one per type per snapshot. Index:
btree(`snapshot_id`).

### `artifacts`

| Column | Type | Notes |
|---|---|---|
| `id` | uuid | PK |
| `snapshot_id` | uuid | FK → snapshots (delete_all). Always set. |
| `component_id` | uuid, null | FK → components (delete_all). Null for `capture` (snapshot-level). |
| `category` | text | `capture` / `extracted` / `derived` |
| `stage` | text | Plugin id |
| `labels` | jsonb | Label map |
| `filenames` | jsonb | Output filenames |
| `path` | text | Relative stage dir |
| `status` | text | `produced` / `failed` / `not_applicable` |
| `version` | integer | Stage version (reprocess invalidation, per ingestion spec) |
| `started_at`/`ended_at` | utc_datetime | |

Current-only / latest-wins (the archive preserves full history). Indexes:
btree(`snapshot_id`), btree(`component_id`), GIN(`labels`), btree(`status`).

### `edges`

| Column | Type | Notes |
|---|---|---|
| `id` | uuid | PK |
| `source_item_id` | uuid | FK → items (delete_all) |
| `edge_type` | text | `embed` / `linked` / `mirror` |
| `target_url_hash` | text | Canonical — what extraction emitted. |
| `target_item_id` | uuid, null | Maintained **cache** of the hash→item resolution; null = dangling. on_delete: nilify. |
| `provenance` | text | `extractor` / `user` |
| `inserted_at` | utc_datetime | |

Stored one canonical (outbound) direction; the inverse (`embedded_in` etc.) is
derived by reverse query. Indexes: btree(`source_item_id`),
btree(`target_url_hash`), btree(`target_item_id`).

### Kept unchanged

`stage_executions` (job tracking — not reindex-rebuilt), `item_messages` (chat —
DB-only), `subscriptions`.

## 7. Edge Resolution & Dangling Edges

An edge is born with only `target_url_hash`. Resolution to an item:

- **Query-time:** join `edges.target_url_hash = url_identities.url_hash` →
  `item_id`. Always correct.
- **Cached:** `edges.target_item_id` is maintained for fast/reverse traversal.
  When a new item's `url_identities` rows are inserted (capture), run
  `UPDATE edges SET target_item_id = <new> WHERE target_url_hash IN (<new hashes>)
  AND target_item_id IS NULL` — this lights up previously-dangling edges the
  moment their target is captured. On item delete, `on_delete: nilify` returns
  them to dangling.

A **dangling edge** (uncaptured target) is simply a `target_url_hash` with no
matching `url_identities` row → `target_item_id` stays null. **No stub item rows,
ever** (resolves the data-model spec's "stub items" open question: always dangling
edges, never a stub entity).

## 8. Amendments to the Ingestion-Rework Spec

These decisions change the already-approved `2026-05-29-ingestion-rework-design.md`
and must be reflected there:

1. **No physical archive move (§11).** Items are created in the archive under
   `ingest-<shorthash>`; "promotion" is an in-place rename (re-slugify). The
   cross-location bootstrap→archive move and `tmp/bootstrap/` are removed.
   `bootstrap_path` is dropped.
2. **The archive handshake leaves the `plan` contract (§4.3).** Its sole purpose
   was coordinating the move. With always-in-archive there is no staging vs.
   permanent location, so the `{:archive}` directive and the `archived` fact are
   removed. `plan` returns `{:run, [stage]} | {:terminal, status}` only.
   Re-slugify is a pure executor side-effect on the first title — not a plan turn.
3. **No `slugify(url)` slug floor (§11).** The temporary name is
   `ingest-<shorthash>`; the final slug is `<slugify(title)>-<shorthash>`. A
   never-titled item keeps `ingest-<shorthash>`.
4. **Bootstrap phase includes the first extraction.** Exit condition shifts from
   "a capture exists" to "first extraction terminal" (title known → re-slugify, or
   no-title terminal). Status gains `extracting` between `bootstrapping` and
   `processing`.

Everything else in the ingestion spec (pure `plan`, projection, executor,
candidate escalation, phases as scheduling discipline, version-based reprocessing)
is unchanged.

## 9. Reindex

Rebuild the index from the archive (the v2 algorithm, extended for the graph):

1. Walk `archive/YYYY/MM/DD/<slug>/` item dirs — **including `ingest-*`
   in-progress items** (now in the archive, not tmp); derive `slug`,
   `archive_path`, `shorthash`→`id` (or read `id` from the input record),
   `first_captured_at` from the dir date.
2. Per `snapshots/<ts>/`: read the `input-<ts>/` record (provenance →
   `snapshots`); scan `capture/stages/*/artifact.json` (capture artifacts +
   `url_identities` from the emitted hashes); scan `components/<type>/stages/*/
   artifact.json` (components, extracted/derived artifacts, **edges** from emitted
   `embeds`/`refers_to` metadata).
3. **Second pass:** resolve every `edges.target_url_hash → target_item_id` via
   `url_identities`.

Modes unchanged from v2: `--full` (wipe + rebuild) and `--upsert` (refresh),
no default. `stage_executions` and `item_messages` are **not** rebuilt.

## 10. v2→v3 Converter (Secondary, Optional)

A low-fidelity one-shot converter, valuable mainly to avoid re-downloading
expensive captures (ytdlp video originals). It does **not** preserve downstream
processing.

- For each v2 `archive/YYYY/MM/DD/<slug>/processing/<stage>-<ts>/`: create a v3
  item dir (`<slug>-<shorthash>`), one snapshot `snapshots/<ts>/`, and move the
  **capture-category** stage outputs (e.g. ytdlp `original.*`) into
  `capture/stages/`. Downstream extracted/derived outputs are dropped.
- Mark the item for reprocessing; run reindex.
- Guarantee: capture bytes survive; everything else is recomputed. Articles
  (cheap to re-fetch) need not be converted at all — re-ingest from the URL.

This is a separate deliverable and does not constrain the core layout.

## 11. Resolved & Deferred

**Resolved here** (were data-model open questions):
- **Stub items** — never; dangling edges only (§7).
- **Slug timing** — create-in-archive + re-slugify rename; no move (§3).
- **Artifact ownership** — per-component only; cross-component is reprocessing
  (§2 rules).

**Still deferred to other designs:** per-user data split; typed-artifact on-disk
contracts + `pgvector`; display transforms; the discovery extractor↔executor
protocol; the exact URL-normalization denylist.

## 12. Open Questions

- **Snapshot-pinned edges.** Edges target items (latest-relevant snapshot
  surfaced). Optional snapshot-pinning ("refers to *that* version") still
  deferred.
- **`url_hash` storage type.** `text` (hex) vs `bytea` — a performance/ergonomics
  detail to settle at implementation.
- **Reverse-edge query vs. materialized inverse.** Whether `embedded_in` is always
  a reverse query or ever materialized for hot paths.
