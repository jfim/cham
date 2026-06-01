# v3 Ingestion Completion — Capture Escalation, Discovery, Throttling — Design

**Date:** 2026-06-01
**Status:** Design / spec. Completes the v3 ingestion story. Builds on and amends:
- `2026-05-29-ingestion-rework-design.md` — the control plane (pure `plan`,
  projection, executor). This spec makes its bootstrap candidate walk concrete and
  adds two executor responsibilities (§6).
- `2026-05-30-v3-data-model-design.md` — resolves its deferred §6 discovery
  "detailed extractor↔executor↔enqueue interaction."
- `2026-05-30-v3-physical-layout-design.md` — amends its §5 (when the `submitted`
  URL identity is written) (§6).

## 1. Motivation and Scope

The three prior v3 specs left three control-plane mechanisms unspecified:

1. **Fetch-escalation** — the ingestion spec built the *slot* (a candidate walk over
   bootstrap producers) but never said how candidates are ordered or how the
   default fetcher sits at the bottom.
2. **Discovery** — the data-model spec gave discovery its *shape* (extract emits
   referents; executor records edges and may enqueue captures) but explicitly
   deferred the mechanism.
3. **Per-domain throttling** — not designed anywhere; only gestured at
   (`changes-for-v3.md`, subscriptions per-host notes).

These three are coupled: discovery fan-out is what makes throttling necessary, and
both ride the same executor that the candidate walk drives. This spec settles all
three so v3 can be released and exercised in practice.

### In scope

- Capture escalation as an explicit ordered config list (chain of responsibility).
- The discovery protocol: extractor contract, disk→DB projection, capture-policy
  seam, submit-path enqueue with dedup, termination.
- A generic keyed throttle gate (used for per-domain capture politeness now;
  reusable for provider throttling later).
- The amendments these decisions force on the three prior specs.

### Out of scope (own specs / deferred)

- Concrete specialized capturers (Twitter, Reddit, …) — added later as ordinary
  entries in the capture order list.
- Config-driven capture *policies* (per-source/per-domain discovery overrides) —
  the policy *seam* is specified; the override config is deferred.
- Provider (Fireworks/Ollama) throttling — the gate is designed to be reusable for
  it, but it is not wired in v3.
- Per-user data split, typed-artifact contracts/embeddings, display transforms —
  separate post-v3-core specs.

## 2. Design Principle: write-to-disk-then-handle

One invariant governs every mechanism here:

> **get metadata → write metadata to disk → handle the on-disk version.**

A stage never hands an in-memory value to a downstream consumer and persists it as
an afterthought. It writes its output (including discovery referents) to its
`artifact.json` first; every consumer — edge projection, discovery spawn, the index
— reads the **on-disk** version back. This keeps the live system and a cold reindex
running the *same* projection over the *same* bytes, and it is why discovery edges
and the index are never written imperatively (§5).

## 3. Capture Escalation (Chain of Responsibility)

Escalation is the ingestion spec's bootstrap candidate walk (§7–8 there), made
concrete with **an explicit ordered config list** — not a per-stage priority field.

```toml
[capture]
order = ["specialized_downloader_a", "specialized_downloader_b", "passe_partout"]
```

- **List position is priority.** `plan` walks the list highest-first, returning
  **one** untried bootstrap candidate at a time (bootstrap is serial/exclusive per
  ingestion §8).
- A candidate decides applicability cheaply (from URL/domain) and returns
  `not_applicable` when it does not match → `plan` advances to the next entry.
- A `failed(category)` that warrants fall-through → advance; otherwise the goal
  fails.
- **passe-partout is the last entry** — the `*` floor that matches every URL, always
  reached last. If it returns a terminal `failed`, no candidate remains → the item is
  `failed` (ingestion's "no capture obtainable" tier; physical-layout §4).

Adding a specialized capturer later is a one-line change: insert its stage id ahead
of `passe_partout` in the list. There is no integer-priority bookkeeping spread
across plugins; the list is the single source of truth for capture order.

## 4. Discovery — Extractor Contract

An extract-phase stage emits, in its `artifact.json`, a list of **primary
referents** — the URLs central to the page's main purpose, and nothing more:

```json
"referents": [
  {"edge_type": "embed",  "url": "https://youtube.com/watch?v=..."},
  {"edge_type": "linked", "url": "https://example.com/the-discussed-article"}
]
```

**The editorial discipline is the fan-out bound.** The default per content-type:

- an **article** emits no referents;
- a **link-aggregator** post (Reddit/HN/Slashdot) emits the one discussed link
  (`linked`) and any embedded media (`embed`);
- a **forum thread** emits its own other pages, never sibling threads.

Because each discovered item runs its own independent `plan` loop (§5), there are no
parent→child depth chains, and hash-set dedup breaks cycles (§5.3). No depth counter
is needed; the bound is editorial restraint in the extractor. The extractor only
*reports* referents — it never decides what is captured (that is policy, §5.2).

`edge_type` is drawn from the data-model's set (`embed` / `linked` / `mirror`).

## 5. Discovery — Executor Handling at Item Finalization

Discovery is an **executor side-effect**, preserving the pure-`plan` contract:
`plan` never takes referents as input — it sees `facts` ("extract produced component
X") and proceeds. The executor reacts to a recorded outcome.

When `plan` returns `{:terminal, status}` for an item (`complete` / `incomplete` /
`failed`), the executor runs a **finalization step** on that item, in two phases.

### 5.1 Phase 1 — project on-disk metadata into the DB

Walk the item's stage `artifact.json` files and project the item's index metadata —
including **edges**, read from every extract stage's `referents`. This is the
**same projection reindex runs** (physical-layout §9 step 2), scoped to one item.
Running it here, rather than writing edges imperatively at extract time, is what
keeps the live index and a cold reindex byte-identical (§2).

Each edge row carries `target_url_hash` (the normalized referent URL hash),
`edge_type`, `provenance = extractor`, and a resolved `target_item_id` if that hash
already maps to an item, else null (dangling — physical-layout §7).

This phase is idempotent: re-finalizing after a reprocess re-projects identical rows.

### 5.2 Phase 2 — spawn discovery

Walk the projected referents; for each, evaluate the **capture-policy seam**:

```
capture?(edge_type, source_ctx, target_ctx) :: :capture | :skip
```

- **v3 default implementation:** `embed → :capture`, `linked → :skip`,
  `mirror → :skip`.
- The signature carries enough context (edge type, source domain + content-type,
  target domain) that smarter policies — "capture the discussed link *from
  aggregators* but not from blogs," "never auto-capture youtube.com" — slot in later
  without touching callers. The config-driven overrides are deferred; the seam is not.

For each `:capture` referent, **enqueue a capture via the submit path** (§5.3).

### 5.3 The submit path and dedup

A `:capture` decision calls the **exact same ingestion entry point** a user / CLI /
API submit calls — there is no separate discovery code path — with
`provenance = {kind: discovery, ref: {parent_item_id, edge_type}}`.

That path, in one transaction, inserts the `items` row + a
`url_identities(role=submitted)` row (and eagerly writes the on-disk input record,
§7.4). `unique(url_hash)` is the **dedup claim**:

- **Race or already-exists** → the insert hits the unique constraint → no new item,
  no duplicate capture. The executor falls back to resolving the edge's
  `target_item_id` to the existing item.
- **New** → item created (`status=bootstrapping`, dir `ingest-<shorthash>`, first
  snapshot input record written), capture enqueued, its own `plan` loop begins.

**Cycle termination falls out of this:** A embeds B, B embeds A → B's discovery of A
finds A's hash already claimed → edge only, no re-capture. A discovered capture that
fails is isolated — its own terminal status, no effect on the parent (independent
`plan` loops joined only by the edge).

### 5.4 Reindex never re-spawns

Reindex runs **Phase 1 only** — it rebuilds the index from disk but never re-spawns
captures (a rebuild is not a re-crawl). Un-captured referents remain dangling edges
until their target is captured by some other means.

### 5.5 Timing consequence

A discovered child is enqueued only *after* its parent fully terminates, so children
never compete with the parent's own remaining processing. Slightly later than an
at-extract-time spawn, but cleaner and exactly reindex-equivalent in Phase 1. (If a
future version moves the trigger to stage-completion, the §2 invariant still holds:
the stage writes `referents` to `artifact.json` first, and the handler reads them
back from disk.)

## 6. Per-Domain Throttling

### 6.1 A generic keyed gate

`Cham.Throttle` enforces, **per key**, a max concurrency and a min interval between
acquisitions. The key is abstract: v3 uses the target page's **registrable domain
(eTLD+1)** for captures; the same gate is reusable later with keys like
`provider:fireworks` (designed for, not wired in v3).

State lives in **ETS**, one entry per key: `{key, active_count, last_completed_at}`.
It is ephemeral runtime state (like Oban's own job state), never archive truth — on
restart it resets, which is harmless for advisory politeness.

### 6.2 Applied at capture scheduling, via snooze

Only `:bootstrap`-phase (capture) stages pass through the gate. Before a capture job
runs, it asks the gate to acquire the target domain's slot:

- **Granted** (`active_count < max_concurrency` **and**
  `now - last_completed_at ≥ min_interval`) → increment `active_count`, run the
  fetch. On terminal outcome → decrement `active_count` and stamp
  `last_completed_at`.
- **Denied** → the Oban job returns `{:snooze, n}`, where `n` is the remaining
  cooldown (or a small default when concurrency-bound) **plus jitter**, so a herd of
  same-domain jobs does not wake together. The job does not hold a worker while
  waiting.

Extract- and process-phase stages do not consult the gate (they do no top-level
remote fetch; sub-resources ride inside passe-partout's own browser session, and
fixed API providers keep their own provider-side rate-limit handling).

### 6.3 Config

```toml
[throttle]
default = { max_concurrency = 1, min_interval_ms = 2000 }

[throttle.domains]
"example.com"          = { max_concurrency = 4, min_interval_ms = 500 }
"crawl-me-gently.org"  = { max_concurrency = 1, min_interval_ms = 10000 }
```

A global default plus per-domain overrides. Unlisted domains use the default.

### 6.4 Interaction with Oban queues

The capture queue's global concurrency limit (currently `network: limit 1`) can be
raised so different domains capture in parallel, while the gate keeps each individual
domain polite. The global limit becomes a coarse cap on total fetch parallelism; the
gate is the per-domain politeness layer beneath it.

## 7. Amendments to Prior Specs

These decisions change already-approved specs and must be reflected there:

1. **Ingestion-rework §7–8 (escalation made concrete).** Bootstrap candidate
   ordering comes from an **explicit ordered config list** (`[capture] order`), not a
   per-stage priority field. passe-partout is the last entry / `*` floor (§3).
2. **Ingestion-rework executor (two new responsibilities).**
   - On `{:terminal, status}`, run the **finalization step**: project on-disk
     metadata → DB (shared with reindex), then spawn discovery (§5).
   - Consult the **throttle gate** before any capture-phase run; snooze on denial
     (§6).
3. **Data-model §6 (discovery resolved).** The deferred extractor↔executor↔enqueue
   interaction is specified here (§4–5): referents on disk → projection → policy →
   submit path.
4. **Physical-layout §5 / §3 (submitted identity written at creation) — this
   spec OVERRIDES the prior decision.** Physical-layout §5 currently says *all*
   `url_identities` rows (both `submitted` and `redirect_alias`) are emitted by the
   capture stage. **That is overridden here.**

   *Why it must change:* if the `submitted` row is only written when capture
   completes, the `unique(url_hash)` dedup claim does not exist during submit/
   discovery. Two submissions or discoveries of the same URL would both pass the
   "is this already an item?" check, both create an item, and **both start
   capturing the same URL** — the constraint only trips long after the redundant
   fetch is already underway. The claim has to be made at creation, not at capture.

   *The override:* the `url_identities(role=submitted)` row is created at **item
   creation**, in the same transaction that inserts the `items` row (the shared
   submit path). That transaction *is* the dedup claim. The capture stage still adds
   the `redirect_alias` rows later (the redirect chain is unknown until the fetch
   happens).

   *Keeping the DB rebuildable:* a freshly-created-but-not-yet-captured item now has
   a DB identity row with no on-disk source (capture hasn't written its
   `artifact.json` yet), which a from-disk reindex would lose — and the source
   item's edge to this target would fail to resolve. So **item creation also writes
   the input record eagerly**, at `snapshots/<creation-ts>/input-<creation-ts>/
   artifact.json`, carrying `{provenance, submitted_url, submitted_hash}` — all known
   at submit time. The first snapshot dir is created at item creation with a
   creation-time timestamp; the capture stage then runs inside that same snapshot.
   (This reuses the existing input-record file type — no new on-disk type — and the
   `submitted_hash` lets reindex rebuild the `submitted` identity from disk so edges
   resolve.) Net: only **redirect aliases** ride the capture stage; the **submitted**
   identity is a creation-time DB row *and* on-disk input record.

Everything else in the three prior specs is unchanged.

## 8. New Units

Each is independently testable:

- **`Cham.Throttle`** — the keyed ETS gate (`acquire/2`, `release/1`,
  `snooze_for/1`); clock injected for tests.
- **`Cham.Discovery.Policy`** — `capture?/3`, pure, with the v3 defaults.
- **Executor finalizer** — on terminal, runs the shared disk→DB projection then
  spawns `:capture` referents via the submit path. Reindex calls the projection only.
- **Shared projection** — the disk→DB metadata/edge projection, called by both the
  finalizer (Phase 1) and reindex.
- **Capture order** — the `[capture] order` list drives the bootstrap candidate walk
  in `plan`; the `phase` field on the stage declaration distinguishes bootstrap from
  extract/process.

## 9. Testing Strategy

- **Throttle (unit):** acquire grants/denies against concurrency + interval; release
  decrements and stamps time; snooze value + jitter computed correctly. Injected
  clock, no Oban.
- **Capture policy (pure unit):** the `embed/linked/mirror` defaults.
- **Projection (unit):** an on-disk item with extract `referents` projects the
  expected edge rows; shared with the reindex tests.
- **Discovery spawn (integration):** finalizing an item with `:capture` referents
  enqueues captures via the submit path; concurrent/duplicate discovery of the same
  URL yields exactly one item (unique-constraint dedup); a cycle (A↔B) terminates.
- **Bootstrap walk (pure `plan`):** list-ordered candidate selection, `not_applicable`
  / `failed` fall-through, passe-partout floor, all-fail → `failed`. Extends ingestion
  §14 plan tests.
- **Identity / reindex:** item creation writes the input record + `url_identities`;
  reindex recovers the submitted identity and the source edge resolves to the target.

## 10. Open Questions

- **`min_interval` clock source under multi-node.** The gate's ETS state is
  per-node; `peer: Oban.Peers.Global` means jobs run on one node at a time, but if
  Cham ever runs multi-node the gate would need a shared store. Single-node is the v3
  assumption; revisit only if multi-node capture becomes a goal.
- **Snooze granularity vs. fairness.** Pure snooze+jitter can let a later-submitted
  job for a quiet domain overtake an earlier one for a busy domain. Acceptable for an
  archiver; note if it ever matters.
- **Registrable-domain extraction.** Computing eTLD+1 needs a public-suffix list;
  whether to vendor one or approximate (last-two-labels) is an implementation choice.
