# v3 Ingestion Rework — Reconciliation & Sequencing

**Date:** 2026-06-01
**Status:** Canonical cross-spec reference. Not a new design — it (a) records the
resolved reconciliations an implementer must apply *on top of* the six base specs,
and (b) sequences the build.

**How to use this doc:** the six v3 ingestion specs amend one another **by
reference** — the base specs were deliberately *not* edited in place. When
implementing a subsystem, read its base spec **plus** the reconciliations in Part B.
Where a base spec passage is listed as superseded here, this doc wins.

## Part A — Spec set & amendment chains

| Spec | Layer |
|---|---|
| `2026-05-29-ingestion-rework-design.md` | Control plane (pure `plan`, projection, executor) |
| `2026-05-30-v3-data-model-design.md` | Conceptual model (Item/Snapshot/Component/Artifact/Edge, identity, provenance, discovery) |
| `2026-05-30-v3-physical-layout-design.md` | Storage (on-disk tree + Postgres schema) |
| `2026-05-31-warc-page-view-design.md` | Rendering (`page` component, WARC resource endpoint) |
| `2026-06-01-passe-partout-capture-design.md` | Capture producer (WARC + CDXJ) |
| `2026-06-01-v3-ingestion-completion-design.md` | Control plane cont. (escalation, discovery, throttling) |

Amendment relationships (who changes whom):

- **physical-layout** amends **ingestion-rework**: removes the physical archive move
  and the archive handshake (§8.1–8.3); bootstrapping lifecycle spans first
  extraction (§8.4).
- **ingestion-completion** amends **ingestion-rework**: escalation ordering is an
  explicit config list, not a per-stage priority field (§3/§7.1).
- **ingestion-completion** amends **physical-layout**: the `submitted` URL identity
  is written at item creation, not by the capture stage (§6.4).
- **ingestion-completion** resolves **data-model** §6 (discovery mechanism).

## Part B — Reconciliations (apply on top of the base specs)

### B1. "Phase" and "status" are two separate concepts (resolves the bootstrap overload)

- **Phase = a stage's scheduling discipline** (ingestion-rework §8), unchanged.
  Three values: `bootstrap` (capture; serial/exclusive candidate walk), `extract`
  (eager fan-out), `process` (goal-directed backward DAG). `plan` branches its
  selection rule on this, and the throttle gate keys off it. **Capture stages are
  the only `bootstrap`-phase stages; the first extraction is an `extract`-phase
  stage.**
- **Status = a lifecycle projection** of which phase holds the active frontier:
  `bootstrapping → extracting → processing → complete | incomplete | failed`.
  Purely a UI/query projection.
- **physical-layout §8.4 wording is corrected:** the *`bootstrapping` status* spans
  capture + first extraction (because re-slugify keys off the first title); the
  first extraction does **not** become a `bootstrap`-*phase* stage. Re-slugify is
  triggered by the first title-bearing extraction's terminal outcome.
- **Consequence for the throttle (ingestion-completion §6.2):** "only `:bootstrap`-
  phase (capture) stages pass through the gate" is correct as written — extraction
  is `extract`-phase and is never throttled.

### B2. Canonical status enum

`bootstrapping → extracting → processing → complete | incomplete | failed`
(physical-layout §4). **data-model §2.1's list is superseded** — `archived` was
dropped when the physical move was removed; `extracting`/`processing` were added
afterward.

### B3. Slug timing — set once, from the first title-bearing extraction

- **Trigger:** the earliest `extract`-phase terminal outcome that **carries a
  title** in its `artifact.json`. Title-less extractions (`render_webpage`) never
  trigger re-slugify.
- **Ordering is safe by construction:** the executor performs the rename + DB
  update synchronously *before* re-invoking `plan` on that outcome. Process stages
  for a component depend on that component's extracted content — the same outcome
  that carries the title — so no process stage can have been scheduled against the
  old path first. No dir-rename-under-running-stage race.
- **Never-titled item keeps `ingest-<shorthash>` permanently** (physical-layout §2);
  no `slugify(url)` floor.
- **A refined title does *not* auto-re-slugify.** The first extraction title sets
  the slug once; a downstream `clean_title` stage updates `items.title` (display)
  only. The on-disk slug is a browsing affordance (`ls`/`find`/`du` legibility,
  GUID→human-readable without parsing JSON), not a user-facing identifier, so a
  stable `archive_path` beats a prettier-but-churning one. Deliberate renames go
  through the explicit re-slugify op (physical-layout §3).

### B4. `download_images` is retired

Deleted (plugin + script + test), like `generic_download_url`. With passe-partout
capturing a self-contained WARC and the §4 resource endpoint serving those bytes,
there is nothing to download. The residual need — rewriting the article component's
image refs to the resource endpoint — is **owned by page-view §9** (the "article-
view rewrite point" decision: inside `extract_article` or as a display transform),
not a standalone fetch stage. No network fallback for images the WARC missed; capture
completeness is passe-partout's job (page-view §1), consistent with retiring the HTTP
fallback.

### B5. Already-amended decisions, restated in one place

So an implementer reading a base spec sees the override without cross-referencing:

- **No archive handshake / no physical move** (physical-layout §8.1–8.2 over
  ingestion-rework §4.3, §11). Items are created in-archive under
  `ingest-<shorthash>`; "promotion" is an in-place re-slugify rename. `plan` returns
  **`{:run, [stage]} | {:terminal, status}`** only — there is no `{:archive}`
  directive and no `archived` fact. `bootstrap_path` and `tmp/bootstrap/` do not
  exist.
- **No `slugify(url)` slug floor** (physical-layout §8.3 over ingestion-rework §11).
  See B3.
- **Escalation is an explicit ordered config list** `[capture] order`
  (ingestion-completion §3 over ingestion-rework §7–8), not a per-stage priority
  field. passe-partout is the last entry / `*` floor.
- **`submitted` identity written at item creation** (ingestion-completion §6.4 over
  physical-layout §5): the `url_identities(role=submitted)` row + the on-disk input
  record are written in the submit-path transaction (the dedup claim). The capture
  stage adds only `redirect_alias` rows.

## Part C — Build strategy

**In-place rewrite on a long-lived branch.** Rewrite the four subsystems
changes-for-v3 names incompatible — data model, pipeline, capture/extraction,
rendering — in the same repo; **keep the infra** (config, event bus, Oban wiring,
LiveView shell, smoke-test harness). **No feature flag, no v2/v3 coexistence.**

- **Cutover gate = Phase 5.** The branch replaces v2 the moment the vertical slice
  "submit URL → passe-partout capture → WARC on disk → extract → browseable item"
  passes the smoke test. Phases 6–8 land after cutover.
- **Migration:** reindex (rebuild the index from the archive) plus the optional
  v2→v3 converter for expensive captures (ytdlp originals). Cheap content
  (articles) is re-ingested from the URL rather than converted.

## Part D — Sequencing

Each phase becomes its own `spec → plan → subagent-driven execution` cycle (per
CLAUDE.md), with this doc as the shared reference. Phases 0 and 1 run concurrently
once the `facts`/`config` shape is pinned.

| Phase | Scope | Depends on |
|---|---|---|
| **0 — Data-model substrate** | Postgres schema + migrations (`items`, `url_identities`, `snapshots`, `components`, `artifacts`, `edges`); Ecto schemas/contexts; on-disk layout module (path construction, create-in-archive, atomic `artifact.json`, re-slugify rename); URL normalization (versioned denylist) + hashing + hash-set lookup. | — |
| **1 — Pure control plane** | `plan(config, facts)`: candidate walk, phase selection, conflict resolution, classification→desired-artifacts, terminal tiers, version invalidation. Pure unit tests, no Oban/DB. | shape of 0 |
| **2 — Projection + reindex** | Build `facts` from disk/DB; the shared disk→DB projection (used by both finalizer and reindex); reindex (`--full`/`--upsert`). | 0 |
| **3 — Executor** | Replaces `Orchestrator`. Oban scheduling from `plan` decisions; in-flight dedup; same-tool retry; liveness→terminal; one durable outcome channel; re-slugify side-effect; submit path (item + `url_identities(submitted)` + eager input record) with unique-constraint dedup; finalization step. | 0, 1, 2 |
| **4 — Capture** | `passe_partout_capture` stage + `warc_index` script (recompress→CDXJ→sort); retire `generic_download_url`; `[capture] order` candidate-walk wiring; `Cham.Throttle` gate via snooze. | 0–3 |
| **5 — Extraction → Components + Discovery** | Port `extract_article` et al. to the Component model (emit extracted artifact, title, referents/edges); content-type-as-result (retire `content_type_router`); `Cham.Discovery.Policy` + executor spawn via submit path. **← cutover gate (vertical slice).** | 0–4 |
| **6 — Page view** | `render_webpage` (Node+DOMPurify via ScriptRunner); WARC resource endpoint (SURT + CDXJ binary-search + range-read); article-image-ref rewrite (B4 / page-view §9); UI toggle. | 4, 5 |
| **7 — Process stages + UI** | Port `summarize`/`transcribe`/`embeddings`/`auto_tag`/`clean_title` to goal-directed process phase + per-component derived artifacts; item-detail UI (components, status, snapshot history); version-invalidation reprocess CLI. | 5 |
| **8 — v2→v3 converter** *(optional/secondary)* | Low-fidelity converter to preserve expensive captures (ytdlp originals). | 0–5 |

**Critical path:** 0 → 2 → 3 → 4 → 5 (cutover). Phase 1 parallels 0; Phases 6–8
follow cutover.

## Part E — Carried-over open questions

Not blockers for sequencing, but each owning phase must resolve them:

- **`facts` source** — projected from the DB index, directly from disk, or both; and
  the exact durable outcome-record shape (the "one channel"). *(Phase 1/2.)*
- **Failure-category set** — final closed set (`:blocked`, `:unsupported`,
  `:bad_input`, `:error`, …) and which warrant candidate fall-through. *(Phase 1.)*
- **URL-normalization denylist** — the exact tracking-param set + canonicalization
  rules (host casing, query ordering, trailing slash). *(Phase 0.)*
- **`url_hash` storage type** — `text` (hex) vs `bytea`. *(Phase 0.)*
- **Article-view rewrite point** — extract-time vs display transform. *(Phase 6.)*
- **Reverse-edge query vs materialized inverse**; **snapshot-pinned edges**.
  *(Phase 6/7.)*
- **eTLD+1 extraction** — vendor a public-suffix list vs approximate. *(Phase 4.)*
- **Multiple same-type components** — index-discriminator scheme. *(Phase 5.)*
