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

### B6. Schema trims (Phase 0 spec over physical-layout §6)

- **`items` has no `content_type` column.** An item has a *set* of component types,
  not a primary one; type filtering queries `components`. Denormalize a `content_types`
  array later only if the join is a hot path (YAGNI).
- **`snapshots` has no `status` column.** Lifecycle is item-level (`items.status`);
  per-snapshot state is derivable from that snapshot's artifacts. Re-add only if a real
  per-snapshot consumer appears.
- See `2026-06-01-v3-phase-0-data-model-substrate-design.md` §3 for the full Phase 0
  schema.

### B7. Process-stage rename / replacement (Phase 5/8 rebuild decisions)

Phase 0a deletes every v2 stage, so these are *naming/structure decisions for the
rebuild*, not edits to live code. Settled 2026-06-01:

- **`summarize_ollama → summarize_llm`.** Provider-agnostic name; the LLM provider is
  Fireworks, not Ollama, so the v2 name was already wrong. Aligns with the Phase 8 LLM
  provider abstraction.
- **`transcribe_fireworks → transcribe_deepgram`.** A *capability* change, not a rename:
  Fireworks dropped Whisper, so ASR moves to Deepgram. Needs a Deepgram client + API key
  in config. Splits vendors: **Fireworks = LLM, Deepgram = ASR**.
- **No LLM-stage fusion.** `summarize`, `auto_tag`, `clean_title` stay **three separate
  stages**, not a fused `llm_postprocess`. Fusion was rejected because it defeats the
  per-artifact **versioned reprocessing** the data model invests in (re-running only
  `auto_tag` after a model upgrade is *cheaper* with separate stages: N calls vs N calls
  doing 3× work each), and a combo+individual pair would need janky override machinery
  (two producers of one artifact type). Provider-agnostic renaming of `auto_tag` /
  `clean_title` is left as a Phase 8 detail.
- **Burst control is a rate gate, not fusion.** The motivation for fusion (bulk reprocess
  flooding the LLM provider — e.g. 1000 articles × 3 calls) is a *concurrency* problem,
  solved by an **LLM-provider rate gate** — the same machinery as the per-domain throttle
  gate (ingestion-completion §6.2), keyed on provider. Deferred to Phase 8; build only if
  it actually bites. Executor-level call coalescing was considered and rejected as
  unnecessary complexity for a personal archive.

## Part C — Build strategy

**In-place rewrite on a long-lived branch.** Rewrite the four subsystems
changes-for-v3 names incompatible — data model, pipeline, capture/extraction,
rendering — in the same repo; **keep the infra** (config, event bus, Oban wiring,
LiveView shell, smoke-test harness). **No feature flag, no v2/v3 coexistence.**

- **Cutover gate = Phase 6.** The branch replaces v2 the moment the vertical slice
  "submit URL → passe-partout capture → WARC on disk → extract → browseable item"
  passes the smoke test. Phases 7–9 land after cutover.
- **Migration:** reindex (rebuild the index from the archive) plus the optional
  v2→v3 converter for expensive captures (ytdlp originals). Cheap content
  (articles) is re-ingested from the URL rather than converted.

**Quality gates land after the teardown (Plan 0a.5).** Enforcing static analysis
against code 0a is about to delete is pure churn, so gates are added *after* 0a, when
the surviving core is small. Plan 0a.5: add `mix format --check-formatted` + `sobelow`
(Phoenix/web + the Phase 7 WARC resource endpoint) + `dialyxir` (success-typing the
Phase 1 typed-artifact contract across the polyglot plugin boundary) + `credo`; run one
cleanup pass over the surviving core; then make the gate **CI-blocking from Phase 0b
onward**. `dialyxir` starts as a *non-blocking* CI job until the PLT cache is stable,
then flips to blocking. This **supersedes the CLAUDE.md "no Credo or other linters"
line** — `mix format` stays the sole *formatting* authority; credo covers
consistency/complexity only. The CLAUDE.md edit is a step *in* Plan 0a.5 (so the doc
never describes tooling that isn't installed yet).

## Part D — Sequencing

Each phase becomes its own `spec → plan → subagent-driven execution` cycle (per
CLAUDE.md), with this doc as the shared reference. **Each phase is designed in its
own session** — the seams below are recorded against their phase, not designed now.

**Scope expansion (2026-06-01):** the polyglot **plugin runtime** is a real phase
(Phase 1) — the Phase 0 teardown removes the v2 runtime and nothing else rebuilds one.
It is the **full kind × class model** (kind = stage/subscriber/integration; class =
in-process Elixir / external subprocess; wire protocol canonical, in-process a fast
path). Two coupled "contract freezes" fold into it because deferring them re-opens the
stage I/O contract / lifecycle later: the **typed-artifact contract** (artifact types
declared in the stage I/O contract; specific on-disk typed layouts still deferred) and
the **`waiting_for_input` outcome** (stage lifecycle + executor allow a needs-input
outcome + resume; concrete input channels — body upload, interactive UI — deferred). A
third candidate, **search-index (`search_vector`) population**, was *downgraded*: it is
a leaf nothing depends on, so Phase 3's projection just leaves a marked stub
(`# search index update goes here`) and real FTS lands with the deferred search feature.

**Phase 1 reductions (design session 2026-06-01, see `2026-06-01-v3-plugin-runtime-design.md`):**
the runtime was scoped down from the above. Only the **`stage`** kind is built in full;
**`subscription`** gets its invocation contract (checkpoint round-trip) but its scheduler +
checkpoint persistence + submit wiring land in **Phase 4/5** (where the submit path exists,
re-homing the RSS backend); **`subscriber`** and **`integration`** are **reserved** (manifest
accepts them, no invocation path). The **`waiting_for_input`** seam was reduced from a
resume mechanism to a **reserved outcome** — returning it fails the item as `:unsupported`;
no resume request kind and no `waiting` lifecycle state (consistent with the B2 status enum).
The wire protocol is **JSONL** (streamed `status`/`progress`/`log` events forwarded to the
EventBus + a terminal `result`), and `can_process` is an **optional separate lightweight
entrypoint** (so a metadata probe need not pay model-load cost). The remaining genuinely
folded-in seam is the **typed-artifact contract** (validated, config/manifest-extensible
type vocabulary living in `artifacts.labels["type"]`; on-disk typed layouts still deferred).

| Phase | Scope | Depends on |
|---|---|---|
| **0 — Data-model substrate** | Postgres schema + migrations (`items`, `url_identities`, `snapshots`, `components`, `artifacts`, `edges`); Ecto schemas/contexts; on-disk layout module (path construction, create-in-archive, atomic `artifact.json`, re-slugify rename); URL normalization (versioned denylist) + hashing + hash-set lookup. | — |
| **1 — Plugin runtime** | Manifest-described, JSONL one-shot wire protocol; kind × class with class = transport (in-process fast path / external subprocess); **`stage` kind in full** (typed I/O, phase, version, optional `can_process` probe entrypoint, `perform`); **`subscription` invocation contract** (opaque-checkpoint round-trip); `subscriber`/`integration` **reserved**; registry/discovery + config-schema registration. Folds in the **typed-artifact contract** seam; freezes the **`{:query_can_process}`** planner seam (impl Phase 2/4). `waiting_for_input` is a **reserved** outcome (→ `:unsupported`), not a resume seam. **See `2026-06-01-v3-plugin-runtime-design.md`.** | 0 (Layout for working dirs) |
| **2 — Pure control plane** | `plan(config, facts)`: candidate walk, phase selection, conflict resolution, classification→desired-artifacts, terminal tiers, version invalidation. Pure unit tests, no Oban/DB. Reasons over Phase 1's stage-declaration contract. | shape of 0, 1 |
| **3 — Projection + reindex** | Build `facts` from disk/DB; the shared disk→DB projection (used by both finalizer and reindex); reindex (`--full`/`--upsert`). **Stub** for `search_vector` population (real FTS deferred). | 0 |
| **4 — Executor** | Replaces `Orchestrator`. Oban scheduling from `plan` decisions; in-flight dedup; same-tool retry; liveness→terminal; one durable outcome channel; re-slugify side-effect; submit path (item + `url_identities(submitted)` + eager input record) with unique-constraint dedup; finalization step; **`waiting_for_input` resume**. Invokes stages via the Phase 1 runtime. | 0, 1, 2, 3 |
| **5 — Capture** | `passe_partout_capture` stage + `warc_index` script (recompress→CDXJ→sort); retire `generic_download_url`; `[capture] order` candidate-walk wiring; `Cham.Throttle` gate via snooze. | 0–4 |
| **6 — Extraction → Components + Discovery** | Port `extract_article` et al. to the Component model (emit extracted artifact, title, referents/edges); content-type-as-result (retire `content_type_router`); `Cham.Discovery.Policy` + executor spawn via submit path. **← cutover gate (vertical slice).** | 0–5 |
| **7 — Page view** | `render_webpage` (Node+DOMPurify via ScriptRunner); WARC resource endpoint (SURT + CDXJ binary-search + range-read); article-image-ref rewrite (B4 / page-view §9); UI toggle. | 5, 6 |
| **8 — Process stages + UI** | Port `summarize_llm`/`transcribe_deepgram`/`embeddings`/`auto_tag`/`clean_title` to goal-directed process phase + per-component derived artifacts (three separate LLM stages, no fusion — B7); **LLM provider abstraction** (restore; v2 hardcodes OpenAI); optional **LLM-provider rate gate** (B7); item-detail UI (components, status, snapshot history); version-invalidation reprocess CLI. | 6 |
| **9 — v2→v3 converter** *(optional/secondary)* | Low-fidelity converter to preserve expensive captures (ytdlp originals). | 0–6 |

**Critical path:** 0a → 0a.5 (quality gates; see Part C) → 0b → 1 → (2, 3) → 4 → 5 → 6
(cutover). Phase 2 (`plan`)
parallelizes Phase 1's *implementation* once the stage-declaration contract is specced;
Phase 3 parallels 1–2. Phases 7–9 follow cutover.

**Explicitly deferred (separable layers on a stable index/contract):** display
transforms (link rewriting, "Cham it"); subscriber/integration *implementations*
(Obsidian/vault sync, reverse-index tables) — the runtime *contract* accommodates the
kinds; full search UX + semantic/`pgvector`; full REST API + research-workspace UI;
per-user data split; embeddings/`pgvector`; mobile; federation.

## Part E — Carried-over open questions

Not blockers for sequencing, but each owning phase must resolve them:

- **`facts` source** — projected from the DB index, directly from disk, or both; and
  the exact durable outcome-record shape (the "one channel"). *(Phase 2/3.)*
- **Failure-category set** — final closed set (`:blocked`, `:unsupported`,
  `:bad_input`, `:error`, …) and which warrant candidate fall-through. *(Phase 2.)*
- **URL-normalization denylist** — the exact tracking-param set + canonicalization
  rules (host casing, query ordering, trailing slash). *(Phase 0.)*
- **`url_hash` storage type** — `text` (hex) vs `bytea`. *(Phase 0.)*
- **Article-view rewrite point** — extract-time vs display transform. *(Phase 7.)*
- **Reverse-edge query vs materialized inverse**; **snapshot-pinned edges**.
  *(Phase 7/8.)*
- **eTLD+1 extraction** — vendor a public-suffix list vs approximate. *(Phase 5.)*
- **Multiple same-type components** — index-discriminator scheme. *(Phase 6.)*
