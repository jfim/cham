# Ingestion / Processing Pipeline Rework — Design

**Date:** 2026-05-29
**Status:** Design / spec. Not yet planned for implementation. Implementation strategy
(and sequencing relative to the deferred data-model work) to be decided once the
companion data-model design exists.

## 1. Motivation

The current ingestion/processing pipeline is brittle and a recurring source of
frustration. The brittleness is not a pile of unrelated bugs — it traces to a single
structural choice: **the mechanical layer and the logical layer are fused inside one
GenServer.**

`Cham.Pipeline.Orchestrator` is simultaneously responsible for:

- the *mechanical* concerns — reacting to Oban job lifecycle, scheduling work, handling
  retries, tracking what is running; and
- the *logical* concerns — deciding which stages are eligible next, and what terminal
  state the item is in.

Because there is no authoritative representation of the item's logical DAG state, the
orchestrator **re-derives it on every event by joining four mechanically-distinct
sources of truth**, each written by a different process, through a different channel,
with different latencies and no transactional consistency between them:

1. artifact rows — written **synchronously** by the StageWorker;
2. `StageExecution` rows with `status: "completed"` — written **asynchronously** by
   `JobTracking.Tracker` via PubSub;
3. `StageExecution` `"failed"` rows;
4. the `oban_jobs` table — Oban's own mechanical state.

Almost every defensive comment in `orchestrator.ex` is an apology for a race in that
reconstruction. The canonical example — *"my download failed, then succeeded, but
processing didn't continue"* — is pinned to `failed_stage_ids/1`, which has to subtract
`produced_stage_ids` because the `"completed"` `StageExecution` row lands *after* the
synchronously-written artifact row, leaving a window in which a retry-succeeded stage
still looks failed. The `maybe_add_fallback` / `stages_that_did_work` / `specialized_for?`
block (~70 lines) is a second instance of the same disease: reconstructing "did the fetch
happen?" across stale execution rows, produced artifacts, and a re-invoked `can_process?`.

**The fix is to separate the two layers behind a one-way contract**, so the logical layer
is *told* outcomes through a single channel and transitions deterministically from a
single authoritative representation, instead of *inferring* them by racing four tables.

## 2. Goals and Non-Goals

### Goals

- Split the pipeline into a **pure logical layer** (state machine / DAG), a **projection**
  that builds its input from durable facts, and a **mechanical executor**.
- Make the logical layer a **pure function** that is testable in isolation from a facts
  snapshot — no clock, no Oban, no live state.
- Replace the racy multi-substrate reconstruction with **one durable outcome channel**.
- Introduce a **failure taxonomy** so escalation, re-entry, and self-healing become
  expressible.
- Make **re-classification and re-entry ordinary** (no terminal `failed` latch blocking
  recovery; on-disk bytes reused).
- Model **bootstrap / extract / process** as distinct **scheduling disciplines**.
- Keep the archive **human-navigable with plain shell tools**.

### Non-Goals (deferred — see §13)

These are **data-model** concerns, not ingest/processing, and belong to a separate v3
data-model spec sequenced after this one:

- One URL yielding multiple representations (e.g. a Reddit URL as link + comment feed).
- Typed links/edges between items.
- Discovery / re-seeding (extraction emitting new seed URLs that become their own items).
- Re-archiving / snapshots (detecting that a page changed over time).
- URL insufficiency as a natural key (composite `(url, role)` / canonical source id).

The fetch-escalation *policy* (a headless-browser / cookie-aware fetcher, or delegating
fetching to passe-partout) is **enabled by** this design but not specified here; the
architecture provides the slot (a lower-priority bootstrap candidate), the concrete
alternate fetchers are a separate effort.

## 3. Architecture Overview

Three components with a strict one-way contract:

```
              ┌─────────────────────────────────────────────┐
              │  durable facts (archive on disk = source of  │
              │  truth; DB = rebuildable index)              │
              └───────────────┬─────────────────────────────┘
                              │ read-only
                              ▼
        ┌──────────────┐   facts    ┌───────────────────────────┐
        │  Projection  │──────────▶ │  State Machine  plan/2     │
        │ (facts from  │            │  PURE: config × facts →    │
        │   disk/DB)   │            │  {:run,[stage]} | {:archive}│
        └──────────────┘            │  | {:terminal, status}     │
                                     └─────────────┬─────────────┘
                                                   │ decision
                                                   ▼
                                     ┌───────────────────────────┐
                                     │        Executor           │
                                     │ schedules via Oban; owns  │
                                     │ dedup/idempotency, same-   │
                                     │ tool retry, transient      │
                                     │ failures, liveness, the    │
                                     │ physical archive move.     │
                                     │ Records each TERMINAL      │
                                     │ outcome through ONE channel│
                                     │ then re-invokes plan/2.    │
                                     └───────────────────────────┘
```

**Control loop:** the executor finishes a unit of work → records its terminal outcome
durably (one write) → asks the projection for fresh `facts` → calls `plan(config, facts)`
→ acts on the decision (schedule stages / perform archive move / mark terminal). There is
no other path by which logical state advances.

### 3.1 State Machine (logical)

A pure function:

```
plan(config, facts) :: {:run, [stage]} | {:archive} | {:terminal, status}
```

- No clock, no Oban, no knowledge of what is currently running.
- May return stages that are already running — it is *proposing* a frontier, not
  *committing* to scheduling. The executor reconciles against reality (see §3.3).
- Deterministic: same `config` + `facts` ⇒ same decision.
- Testable in isolation by constructing a `facts` value and asserting the decision.

### 3.2 Projection (facts)

Builds `facts` **only from durable, completed outcomes**. It reads the archive (source of
truth) and/or the DB index (rebuildable from the archive). It **never reads "what is
running."** In-flight state does not enter the logical layer at all (see §5).

### 3.3 Executor (mechanical)

Owns everything mechanical:

- Scheduling work via Oban.
- **Idempotency / dedup** — it holds the authoritative, up-to-the-moment view of in-flight
  jobs, so it is the sole authority that refuses to schedule a stage already
  queued/running. (Deduping here checks the source of truth; deduping in the projection
  would race a stale copy — today's bug.)
- **Same-tool retry** and **transient failures** — never surfaced to the planner.
- **Liveness / timeouts** — detecting a crashed or stuck stage and turning it into a
  durable terminal outcome. The planner never reasons about wall-clock time.
- The **physical archive move** (§11).
- Recording each terminal outcome through **one** channel, then re-invoking `plan/2`.

## 4. The `plan` Contract

### 4.1 Inputs

**`config`** — system-level, identical for every item:

- The stage catalog: each stage's input matchers, output labels, **phase**, and
  **version** (§10).
- Which plugins/stages are enabled.
- **Priority ordering** of stages — drives conflict resolution and escalation (§7, §8).

**`facts`** — per-item, projected from durable outcomes:

- Every stage that has a recorded **terminal outcome** for this item, the outcome
  (§6), and the artifacts it emitted (with labels and **category**, §9).
- The seed `input` artifact (the submitted URL and user metadata).
- Whether the item has been **archived** yet — i.e. promoted from the bootstrap
  staging location to its permanent slug-named location (§11). This is what gates the
  archive handshake (§4.3).

**Desired artifacts are *not* a separate input.** They are derived **inside** `plan` from
`config` (a `classification → [desired artifacts]` mapping) applied to the item's
**current classification**, which is itself a produced fact. Because classification is a
result of extraction (§9.1), a later extract outcome recomputes the desired set, and
re-routing falls out as an ordinary frontier change — no mid-DAG mutation, no failure.

### 4.2 Outputs

- `{:run, [stage]}` — the eligible frontier the executor should (idempotently) schedule.
- `{:archive}` — all reachable capture-producing stages have terminal outcomes and the
  item is **not yet archived**; it should be promoted to its permanent archive location
  (§11).
- `{:terminal, status}` — no further progress is possible; the item's final status is
  `status` (§9.2).

### 4.3 The archive handshake

Archival is not a special control path — it is one turn of the ordinary
outcome→replan loop, gated by the `archived` fact:

1. Capture-producing stages reach terminal outcomes; the item is still
   `archived = false`. `plan` returns `{:archive}`.
2. The executor performs the physical move (§11) and records the item as archived.
3. The executor re-invokes `plan` with **the same facts plus `archived = true`**. Now
   `plan` no longer returns `{:archive}` (the guard is satisfied) and instead returns the
   `{:run, [stage]}` frontier for extract/process.

Extract and process stages are therefore only scheduled **after** archival, so they
operate on files in the permanent location rather than the bootstrap staging directory.
`plan` remains pure: the same `(config, facts)` always yields the same decision, and the
`archived` flag is simply one of the facts.

## 5. In-Flight State Stays Out of the Logical Layer

This is the load-bearing decision that removes the root cause.

The planner is consulted only at moments when a definite outcome just landed (or at
kick-off). Between those moments, nothing should be scheduled anyway. Therefore the
planner never needs to know "stage X is running":

- **Escalation** is expressed over *terminal* outcomes, not liveness. "B is eligible iff A
  has a `failed` outcome (of a fall-through-warranting category)." While A is running or
  not-yet-started — both simply "no terminal outcome" — B is not eligible. The planner
  cannot prematurely start a fallback.
- **Double-scheduling** is prevented by the executor, which holds the authoritative
  in-flight view. The planner may return an already-running stage; the executor drops it.
- **Liveness** (a stage stuck forever) is a timeout/recovery concern owned by the executor;
  it eventually produces a terminal outcome the planner can act on.

The only policy that would genuinely require the planner to see liveness — *speculative
ordering* ("hold an expensive stage because a cheaper one still running might make it
unnecessary") — is explicitly **not** a requirement (YAGNI).

## 6. Stage Outcome Taxonomy

Failure is not one thing. Each stage reports a terminal outcome, and **the stage assigns
it** (it knows *why* it succeeded or failed):

- `produced` — the artifact(s) exist.
- `not_applicable` — a **first-class, post-hoc** outcome: "I ran, looked at the inputs,
  and there is nothing here for me" (e.g. the article extractor on a 10-word video
  caption; a Reddit video downloader on a text post). Distinct from failure: it advances
  the candidate walk (§7) without burning the item.
- `failed(category)` — the stage tried and could not produce its output. Category is a
  small closed set, e.g. `:blocked` (bot wall / 403), `:unsupported`, `:bad_input`
  (fetch succeeded, content unparseable), `:error` (code bug / uncaught). The executor
  assigns a default category only for crashes/uncaught exceptions.

**Transient failures never reach the planner.** "Network blip, retry the same tool" is
owned entirely by the executor; only the eventual terminal outcome is recorded.

The **category drives eligibility**: a `:blocked` failure makes the next bootstrap
candidate (a different fetcher) eligible and must *not* burn same-tool retry budget; a
`:bad_input` failure reopens *extraction* (the bytes are fine) without re-fetching; a
genuinely terminal category fails the goal.

## 7. Candidate Sets, Conflict Resolution, and Escalation

For any artifact goal there is a **priority-ordered set of candidate producers** (from
`config` ordering). The planner walks it by outcome:

- `produced` → goal satisfied, stop.
- `not_applicable` → skip to the next candidate.
- `failed(category)` → advance to the next candidate **only if the category warrants
  fall-through**; otherwise the goal fails.

**OR vs AND falls out of labels, with no special-casing:**

- **OR** (alternatives): candidates declaring the *same* output labels are competing
  producers; the first success wins (this is conflict resolution and escalation — they are
  the same mechanism).
- **AND** (independent): candidates declaring *different* output labels both run if both
  apply.

This **deletes the special-cased `generic_download_url` fallback**: the generic HTTP
archiver is simply the lowest-priority bootstrap candidate (matches `*`), reached
naturally when everything above it returns `not_applicable`/fails.

## 8. Phases as Scheduling Disciplines

A stage declares a **phase**. Phase is *not* about artifact semantics (that is category,
§9) — it is the **selection strategy** the planner applies, and it changes *what `plan`
returns*:

- **Bootstrap — serial, exclusive, ordered-with-fallback.** Candidates are mutually
  exclusive alternatives for "obtain the capture," so they are not run in parallel.
  `plan` returns **one** untried bootstrap candidate at a time, highest priority first; on
  its `failed`/`not_applicable` it returns the next; the generic archiver is the bottom
  candidate. Bootstrap exits the moment a capture exists. (Serialization falls out of the
  outcome-driven loop — the planner returns candidate 1, sees its outcome, returns
  candidate 2, etc.)
  - *Nuance:* candidates must be able to decide applicability **cheaply** (usually from
    the URL/domain). When applicability can only be known *after* fetching (e.g. "is there
    a video in this Reddit post?"), that decision belongs in **extract**: bootstrap fetches
    the generic page once, and extract-phase stages inspect it and pull specialized
    resources. Do not model "is there a video?" as a bootstrap candidate that re-fetches.

- **Extract — eager fan-out, not goal-gated.** `plan` returns **all** applicable extract
  stages at once. They run unconditionally (you want the readable text regardless of
  whether a summary was requested). Each returns `produced` / `not_applicable`. May be
  empty when bootstrap already produced the semantic content (e.g. yt-dlp).

- **Process — goal-directed backward DAG.** `plan` returns the eligible frontier **only on
  paths toward desired artifacts**. Example: desired = summary, available = video ⇒ build
  `video → extract_audio → transcribe → summarize`. Expensive work is only done when wanted.

`plan` stays pure; it simply branches its selection rule on the phase of the stages under
consideration.

## 9. Artifact Category, Failure Tiers, and the Archive Trigger

Orthogonal to phase, every emitted **artifact carries a category** (refining today's
`origin: original | derived`):

- **capture** — bytes obtained from outside (a download).
- **extracted** — semantic content derived from a capture (article text, the canonical
  video, pdf text).
- **derived** — enrichment (summary, transcript, tags, cleaned title).

Category lives on the **artifact**, not the stage, so a single stage may **straddle**: yt-dlp
emits a *capture* (the mp4) plus item metadata plus — if the video ships subtitles — a
*derived* transcript. That derived transcript **pre-satisfies the transcription goal**, so
the expensive Whisper stage is never scheduled. This straddle is exactly why category and
phase must be separate concepts.

### 9.1 Classification is a result, not a precondition

There is **no standalone pre-fetch classifier** writing a mutable `content_type` column
last-writer-wins. The content type is *which extractors succeeded*: the article extractor
says "not an article" (`not_applicable`); the video extractor says "yes." This eliminates
premature branch commitment (the "article that's really a video" bug) — nothing commits a
branch before extraction has looked. Any normalized content-type value for UI/query is a
consistent **derived projection** over extract outcomes, not a piecemeal scalar.

### 9.2 Three failure tiers → terminal status

Computed by `plan` from facts and artifact categories:

- **No capture obtainable** (all bootstrap candidates `failed`/`not_applicable`) →
  `failed`. Nothing to keep.
- **Capture obtained, nothing extracted** (extract produced no `extracted` artifact) →
  kept and **browseable as the raw capture**, marked unclassified — distinct from both
  fatal and complete. This resolves the `null` content_type ambiguity ("never reached" vs
  "reached and couldn't tell").
- **Extracted, but some desired derived artifacts failed/unreachable** → `incomplete`.
- **All desired artifacts produced** → `complete`.

## 10. Reprocessing via Versioned Stages + Invalidation

- Each stage carries a **version number**.
- Every recorded outcome **stamps the version** that produced it.
- Reprocessing is an **invalidation query**, e.g. `invalidate extract_article where
  version <= 5`. Matched outcomes are dropped; because eligibility is "no *valid* terminal
  outcome recorded," the frontier reopens for exactly those nodes, **reusing all upstream
  artifacts** (bytes already on disk) — no re-fetch, no `failed` latch to fight.

This gives self-healing on demand: fix a parser, bump its version, run the invalidation
query, and affected items re-run only the fixed stage. **Automatic** reopening on any
version bump is intentionally **deferred** (it would risk surprise mass-reprocessing on
deploy — e.g. re-summarizing thousands of items); if ever added it is opt-in per stage.

## 11. Archiving

- The item is staged in `tmp/bootstrap/<id>/` during bootstrap and **physically moved** to
  its permanent slug-named location once capture is complete. This move is intrinsic: the
  destination path contains the **slug**, the slug needs a title, and the title needs a
  fetch (`slugify(url)` is the floor, so a slug always exists).
- Promotion is **eager**: as soon as all reachable capture-producing stages have terminal
  outcomes, `plan` emits `{:archive}` and the **executor performs the move**, records
  `archived = true`, and re-invokes `plan` (the handshake, §4.3). Extract/process stages
  are only scheduled on that second invocation, so they operate on the permanent location;
  the item is browseable while they continue. This replaces the hand-rolled
  `transition_to_archive` (and its `bootstrap_path`/`archive_path` nil-juggling) with a
  fact query + a directive.

**Constraint:** the archive must remain **navigable with plain shell tools** — directory
names carry human meaning (date + slug), never opaque ids. (`ls archive/2026/05/` must
answer "what did I read in May.") This is why directories are slug-named and the move is
kept, rather than naming directories by stable id (which would eliminate the move but make
the archive opaque).

## 12. Error Capture

Resolved, and not an architectural change:

- The **full, unfiltered** stage output (progress spam and all) is written to the
  **per-stage log file** (`stages/<stage_id>/<stage>.log`); the layout already provides
  per-stage directories.
- The recorded **outcome** carries only the **category** plus a **short tail** for UI/DB.

No ring-buffer-in-the-database machinery is needed: the log file is the complete record,
and the category is what makes failures queryable and post-mortem-diagnosable without
re-running the job.

## 13. Deferred / Out of Scope

Data-model concerns, for a separate v3 data-model spec sequenced after this one:

- Same URL → multiple representations (Reddit = link + comment feed).
- Typed links/edges between items.
- Discovery / re-seeding (extract emitting new seed URLs as their own items) — when it
  lands, it wants **per-source rule control** ("don't pull videos from this blog"), not
  unconditional fan-out.
- Re-archiving / snapshots (did an article/blog post change over time?).
- URL insufficiency as a natural key (composite `(url, role)` / canonical source id).

Enabled-but-not-specified here: fetch-escalation policy / alternate fetchers
(headless browser, cookie-aware client, passe-partout delegation). The architecture
provides the slot (a lower-priority bootstrap candidate); the fetchers themselves are a
separate effort.

## 14. Testing Strategy

- **State machine** — pure unit tests: construct a `facts` snapshot + a `config`, assert
  the `plan/2` decision. Covers candidate walking, phase selection, conflict resolution,
  classification-driven desired-artifact recomputation, terminal-status tiers. No Oban,
  no clock, no DB.
- **Projection** — tests that a given on-disk archive state (and/or DB index) produces the
  expected `facts`, including re-derivation from disk alone.
- **Executor** — integration tests for idempotency/dedup, same-tool retry, transient
  handling, liveness/timeout → terminal outcome, and the archive move. The mechanical
  concerns are tested where they live, not entangled with logical assertions.

## 15. How This Addresses the Known Challenging Items

Audited against `design-docs/challenging-pipeline-items.md`:

| Challenging item | Verdict |
|---|---|
| Transient download failure (fail then retry-succeed) | **Structurally impossible to mishandle** — one terminal outcome via one channel; no multi-attempt reconciliation. |
| Malformed HTML (fetch ok, extract broke) | **Handled** — `failed(:bad_input)`, item kept browseable; fix + version bump + invalidate re-runs extract on disk bytes. |
| Anti-bot walls (403) | **Handled in principle** — `failed(:blocked)` escalates to next bootstrap candidate, no wasted same-tool retries; *rescue* requires an alternate fetcher to exist (scope). |
| Articles that are really videos | **Premature commitment fixed** (extractor returns `not_applicable`); full rescue needs an embed-extractor stage (within-item, supported) — separate-item framing is deferred. |
| Content-type label inconsistency | **Handled** — content type derived from extract results, not a mutable last-writer-wins scalar. |
| "Unknown type" ambiguity (null) | **Handled** — failure tiers distinguish "never reached" from "reached, unclassified." |
| Pipeline fully linear / no rerouting | **Handled** — re-classification is an ordinary frontier change. |
| Self-selected handler with no fallthrough | **Handled** — serial candidate walk + first-class `not_applicable`. |
| Error-capture truncation | **Handled** — per-stage log + category/tail (§12). |
| Item has one piece of content / URL not a key | **Deferred** — data-model (§13); these will not ingest fully until v3 data-model lands. |

## 16. Open Questions

- Exact failure-category set (`:blocked`, `:unsupported`, `:bad_input`, `:error`, …) and
  which categories warrant candidate fall-through.
- Whether `facts` is projected from the DB index, directly from disk, or both, and the
  precise shape of the durable outcome record (the "one channel").
- Migration: the on-disk layout is unchanged (slug-named dirs stay), but the DB
  representation of stage outcomes / versions changes; rebuild-from-archive is the
  recovery path.
- Final sequencing relative to the v3 data-model work (this spec stands alone, but the
  implementation order across both is undecided).
