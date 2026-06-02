# v3 Phase 2 — Pure `plan(config, facts)` Control Plane — Design

**Date:** 2026-06-02
**Status:** Design / spec. Approved; not yet planned for implementation.
**Phase:** 2 of the v3 ingestion rework (see
`2026-06-01-v3-ingestion-reconciliation-and-sequencing.md`, Part D).

## 1. Scope

Phase 2 builds the **pure logical layer** of the ingestion pipeline: the function
`plan(config, facts)` and the data contracts it reasons over. It is deterministic,
side-effect-free, and unit-tested from hand-built fixtures — no Oban, no DB, no clock,
no knowledge of what is currently running (ingestion-rework §3.1, §5).

`plan` decides the next move for a single **snapshot** (one ingestion attempt of an
item). It reasons over Phase 1's stage catalog (`Cham.Plugin.Manifest` — typed I/O,
phase, version, `can_process` capability) and emits the frozen `{:query_can_process}`
directive (plugin-runtime §5.5) alongside `{:run, …}` / `{:terminal, …}`.

### 1.1 What Phase 2 ships

All modules are pure (no process, no I/O):

- `Cham.Plan` — `plan/2` and the core loop.
- `Cham.Plan.Catalog` — the system-level `config` value: a view over the registry's
  stage manifests plus config-derived orderings/mappings.
- `Cham.Plan.Facts` — the per-snapshot `facts` value.
- `Cham.Plan.Outcome` — the durable outcome record's in-memory shape.

### 1.2 Contract ownership

Phase 2 **owns and defines** `Facts`, `Outcome`, and `Catalog` as authoritative pure
data structures. Phase 3 (projection) later *populates* `Facts`/`Outcome` from the DB
index / on-disk archive; Phase 4 (executor) *records* outcomes into that shape and
*acts on* `plan`'s directives. Phase 2 builds these values by hand in its tests.

### 1.3 Out of scope

- The **projection** that builds `facts` from disk/DB (Phase 3).
- The **executor**: Oban scheduling, in-flight dedup, same-tool retry, transient
  handling, liveness/timeout → terminal outcome, running the `can_process` probe,
  the re-slugify side-effect, the submit path, the outcome→replan loop (Phase 4).
- **Discovery** — extraction emitting *new items* (Phase 6). Phase 2 is component-aware
  *within one snapshot* but does not spawn new items.
- The **durable persistence** of outcomes and probe results (Phase 3/4). Phase 2 only
  documents where they live (§4.3).
- The **invalidation operation** for versioned reprocessing — the transform that prunes
  stale outcomes, its trigger (CLI / executor), and its cascade semantics (Phase 4/8).
  Phase 2 contributes only the `version` field on `Outcome` and `plan`'s reopen-on-missing
  behavior (§9).

## 2. Reconciliations applied

This spec is written against the reconciliation doc, not the raw base spec. The
load-bearing overrides:

- **B5 — no archive handshake.** `plan` returns **`{:run, …}` | `{:query_can_process,
  …}` | `{:terminal, status}`** only. There is **no `{:archive}` directive and no
  `archived` fact** (the physical move was removed; items are created in-archive).
  Base-spec §4.2/§4.3/§11 are superseded.
- **B2 — status enum.** Terminal `status ∈ {:complete, :incomplete, :failed}`. The
  transient lifecycle states (`bootstrapping`/`extracting`/`processing`) are a *UI/query
  projection* of which phase holds the active frontier — not values `plan` emits.
  `unclassified` and `archived` are gone.
- **B1 — phase vs. status.** A stage's `phase` (`:bootstrap` | `:extract` | `:process`)
  is its **scheduling discipline**; `plan` branches its selection rule on it. Capture
  stages are the only `:bootstrap`-phase stages; the first extraction is `:extract`-phase.
- **B5 — escalation is an explicit ordered config list** (`[capture] order`), not a
  per-stage priority field. passe_partout is the last entry / `*` floor.

## 3. The `config` contract — `Cham.Plan.Catalog`

System-level, identical for every item, derived from the Phase 1 registry catalog plus
`cham.toml`:

```
%Cham.Plan.Catalog{
  stage_manifests:        %{stage_id => Cham.Plugin.Manifest.t()},
  capture_order:          [stage_id],
  classification_desired: %{content_type => [artifact_type]}
}
```

- **`stage_manifests`** — the enabled `kind: :stage` plugins (the registry also catalogs
  subscriptions/etc.; `plan` ignores those). The `Manifest.t()` struct is **reused
  directly** — it is already a pure value, and a parallel slim struct would drift. `plan`
  reads `phase`, `version`, `inputs`/`outputs` (typed I/O: `%{type, labels}`), and
  whether `entrypoints.can_process` is present (the probe-capability flag).
- **`capture_order`** — the ordered escalation list of bootstrap-phase capture stage ids.
  Highest priority first; passe_partout (the `*` floor) last.
- **`classification_desired`** — maps a component's `content_type` to the artifact
  *types* desired for it, e.g. `"article" => ["summary", "readability_markdown"]`,
  `"video" => ["transcript", "summary"]`. Drawn from config. This is the
  `classification → [desired artifacts]` mapping of base-spec §4.1, applied per component.

## 4. The `facts` contract — `Cham.Plan.Facts`

Per-snapshot, built only from durable terminal outcomes (ingestion-rework §3.2). It
**never carries in-flight state** — "stage X is running" does not exist in the logical
layer (§5 of the base spec; this is the root-cause fix).

```
%Cham.Plan.Facts{
  item_id:       String.t(),
  snapshot_id:   String.t(),
  submitted_url: String.t(),               # the seed input
  user_metadata: map(),                    # submitted metadata
  components:    [%{id: String.t(), content_type: String.t()}],
  outcomes:      [Cham.Plan.Outcome.t()],
  probes:        [%{stage_id: String.t(), component_id: String.t() | nil,
                    result: :applicable | :not_applicable}]
}
```

### 4.1 Components

`components` is the set of components extraction has produced so far. Each carries its
`id` and `content_type` (`article` / `video` / `image` / `file` / …). Per
ingestion-rework §9.1, **classification is a result, not a precondition**: whichever
extractor produces a component stamps its `content_type`; there is no pre-fetch
classifier. `content_type` is what `classification_desired` keys on.

`components[].id` is the component identity that `outcomes[].component_id` and
`probes[].component_id` reference. A `component_id` of `nil` means snapshot-level
(capture, and extract stages running on the whole snapshot before any component exists).

The DB has `unique(snapshot_id, content_type)` — at most one component per content_type
per snapshot. **Multiple same-type components stay deferred** (reconciliation Part E).

### 4.2 `Cham.Plan.Outcome`

One terminal record per `(stage_id, component_id)`:

```
%Cham.Plan.Outcome{
  stage_id:         String.t(),
  component_id:     String.t() | nil,
  status:           :produced | :not_applicable | :failed,
  failure_category: :blocked | :unsupported | :bad_input | :error | nil,  # only when :failed
  version:          pos_integer(),                                        # version that produced it
  artifacts:        [%{type: String.t(), labels: map(),
                       category: :capture | :extracted | :derived}]
}
```

- `status` matches the Phase 1 outcome taxonomy (plugin-runtime §5.4). `waiting_for_input`
  is *not* a `plan`-visible status — Phase 1 maps it to `failed(:unsupported)` at the
  executor before it ever becomes a fact.
- `failure_category` is set only on `:failed`. It is **metadata** for `plan` (see §6); it
  does not gate the candidate walk.
- `version` is the producing stage's `manifest.version`, stamped per ingestion-rework §10.
- `artifacts` lists what a `:produced` outcome emitted, each with its `type` (from the
  Phase 1 vocabulary) and `category` (capture / extracted / derived, per §9 of the base
  spec — category lives on the artifact, so a single stage may straddle, e.g. yt-dlp
  emitting a *capture* mp4 plus a *derived* subtitle transcript).

### 4.3 Durable homes (documented here; implemented Phase 3/4)

- **`failure_category`** rides in `artifacts.labels["failure_category"]` — no Phase 0
  schema change, mirroring Phase 1's type-in-labels decision.
- **Probe results** — Phase 4 chooses storage. A `:not_applicable` probe is
  walk-equivalent to a `not_applicable` outcome; an `:applicable` probe must persist so
  `plan` does not re-probe. For Phase 2 they are plain `Facts` fields.

## 5. `plan/2` output

```
plan(catalog, facts) ::
    {:run,               [stage_ref]}
  | {:query_can_process, [stage_ref]}
  | {:terminal,          :complete | :incomplete | :failed}
```

A `stage_ref` is `{stage_id, component_id}` (`component_id` `nil` for capture /
extract-on-snapshot) so the executor knows what to run the stage against.

`plan` *proposes* a frontier; it may name stages that are already running. The executor
reconciles against reality and drops duplicates (ingestion-rework §3.3, §5). `plan` is
**deterministic**: the same `(catalog, facts)` always yields the same decision.

## 6. The candidate walk (uniform fall-through)

For any artifact goal there is a candidate set of producer stages (capture: the
`capture_order` list; extract/process: stages declaring the goal's output type). `plan`
walks it by outcome:

| Outcome of a candidate | Action |
|---|---|
| `produced` | goal satisfied — stop |
| `not_applicable` | advance to next candidate |
| `failed(_any category_)` | advance to next candidate |
| `:not_applicable` probe | advance to next candidate (treated like a `not_applicable` outcome) |

**Fall-through is uniform: any terminal outcome that is not `produced` advances the
walk.** A goal **fails only when its candidate set is exhausted** (every candidate,
including the `*` floor, returned non-`produced`).

This is a deliberate simplification of base-spec §6–7's "category drives eligibility"
wording. The failure **category does not gate the in-run walk**; it is recorded as
metadata and consumed elsewhere:

- **Executor retry budget** (Phase 4): `:blocked` / `:error` must not burn same-tool
  retries; `not_applicable` is not a failure at all.
- **Terminal-status diagnostics** (§8): colors *why* an exhausted goal failed, and
  splits the no-extraction tier.
- **Versioned-reprocessing trigger** (§9): `:bad_input` is the documented
  "fix the parser, bump version, invalidate → reopen on the on-disk bytes" hook — a
  separate flow, never an in-run sibling fall-through.

Rationale for uniform fall-through: combined capture/extract stages (e.g. a tweet
downloader that fetches *and* parses) cannot judge applicability until they have the
bytes; "this isn't a tweet" surfaces as `:bad_input`, and the item must still fall
through to the next capturer and ultimately the passe-partout `*` floor. Gating
fall-through on category would strand such items.

**OR vs. AND falls out of output labels with no special-casing** (base-spec §7):
candidates declaring the *same* output type are competing producers (first `produced`
wins — conflict resolution and escalation are the same mechanism); candidates declaring
*different* output types are independent and both run if both apply.

## 7. Phase selection rules

`plan` branches its selection rule on stage `phase`. The output is always a frontier
list (or a probe/terminal directive); phases differ in *how the frontier is chosen*.

### 7.1 Top-level regimes (evaluated in order)

**1. Capture — bootstrap (serial, exclusive).** Walk `capture_order` (§6):
- first `produced` → capture satisfied; proceed to regime 2;
- the next untried candidate (no outcome, no probe fact): if it advertises `can_process`
  → `{:query_can_process, [{id, nil}]}`; else `{:run, [{id, nil}]}`;
- a non-`produced` outcome or `:not_applicable` probe → advance;
- list exhausted, nothing produced → `{:terminal, :failed}`.

Bootstrap returns **at most one** candidate at a time. Serialization falls out of the
outcome-driven loop — `plan` returns candidate 1, the executor records its outcome,
`plan` returns candidate 2, etc. (base-spec §8). Nothing else is scheduled until a
capture exists.

**2 + 3. Extract + Process (combined frontier).** Once capture is `produced`, extract and
process proceed in parallel; `plan` computes a single frontier across both:

- **Extract frontier (eager fan-out):** every `:extract`-phase stage whose declared input
  types are available in `facts` and has no terminal outcome yet. They run unconditionally
  (you want the readable text regardless of whether a summary was requested). May be empty
  when capture already produced the semantic content (e.g. yt-dlp).
- **Process frontier (goal-directed backward DAG):** for each known component, derive its
  desired artifact types via `classification_desired[content_type]`; for each desired type
  not yet `produced`, walk *backward* through producer candidates; the eligible nodes
  (declared inputs satisfied, no valid outcome) join the frontier. Expensive work happens
  only on paths toward a desired artifact. A `derived` artifact that arrived as a straddle
  (e.g. yt-dlp subtitles pre-satisfying the transcript goal) means that path is already
  satisfied and contributes nothing.

### 7.2 Probe-first ordering

`plan` emits one directive per call, so when the combined frontier mixes
probe-needing and ready-to-run stages it **resolves probes first**: if any frontier stage
advertises `can_process` and lacks a probe fact → `{:query_can_process, [all such
stage_refs]}`. Otherwise → `{:run, [the ready set]}` (stages with no `can_process`, plus
those with an `:applicable` probe fact). The executor runs the probes (cheap), records
the facts, and re-invokes `plan`; the run frontier goes on the next call.

Cost: a no-probe stage waits one extra loop if a sibling needs probing. Accepted as far
simpler than mixing two directive kinds or returning a combined frontier. Bootstrap
already probes one candidate at a time (regime 1), so probe-first there is inherent.

A stage **without** `can_process` is route-and-run: `plan` emits `{:run, …}` directly and
applicability arrives post-hoc as a `not_applicable` *outcome* from `perform`, which then
advances the walk (plugin-runtime §5.2).

## 8. Terminal status

When no frontier remains, `plan` returns `{:terminal, status}`:

| Condition | Status |
|---|---|
| capture goal exhausted, nothing captured | `:failed` |
| captured; extraction produced no `extracted` artifact **and** ≥1 extractor `failed` | `:incomplete` |
| captured; extraction produced no `extracted` artifact and all extractors `not_applicable` | `:complete` |
| captured + extracted; all desired per-component artifacts produced | `:complete` |
| captured + extracted; a desired derived artifact's candidate set is exhausted unproduced | `:incomplete` |

The middle two rows resolve base-spec §9.2's "capture obtained, nothing extracted" tier
onto the B2 enum using the category metadata: all-`not_applicable` means there was
genuinely nothing to extract (e.g. a submitted image — a complete archive), whereas an
extractor `failed` means content was expected but the parser broke (a reprocessing
candidate, hence `:incomplete`). A captured item is browseable as the raw capture in
either case.

*Note (Phase 6, not planner logic):* a generic `file` extractor can serve as the
extraction `*` floor — always producing a `file`-typed `extracted` artifact the way
passe-partout is the capture floor — making the all-`not_applicable` row rare. `plan`
already accommodates it: it is just another extract candidate that satisfies the
extraction goal.

## 9. Versioned reprocessing (Phase 2's contribution only)

The full reprocessing story (base-spec §10): fix a parser, bump its stage `version`, and
re-run that stage on the *bytes already on disk* — no re-fetch. The mechanism is that
`plan`'s eligibility is "no *valid* terminal outcome recorded," so removing the stale
outcomes from the facts reopens exactly those nodes on the next `plan` call.

**`plan` itself is not version-aware and never compares versions.** An invalidated node
and a never-run node are identical to `plan` — both simply lack an outcome — so the
reopen behavior is inherent to the candidate walk (§6). Phase 2 therefore contributes
only two things to reprocessing, both already in the design:

- `Outcome` carries the producing stage's **`version`** (§4.2), so the future trigger can
  target which outcomes to prune.
- `plan` **reopens any node lacking a valid outcome** — its default behavior.

The actual **invalidation operation** — the `facts → facts` prune transform, its trigger
(a `mix cham.reprocess`-style CLI / executor path), and its **cascade semantics** (when
`extract_article` reopens, whether the still-versioned downstream `summary`/`tags`
outcomes also reopen) — lives with its consumer in **Phase 4/8**, not here. **Automatic**
reopening on any version bump stays deferred (it risks surprise mass-reprocessing on
deploy); if ever added it is opt-in per stage (base-spec §10).

## 10. Testing strategy

Pure unit tests only — construct a `Catalog` + `Facts` fixture, assert the `plan/2`
decision (base-spec §14). No Oban, no clock, no DB. Coverage:

- **Capture walk:** first-candidate `produced` stops; `not_applicable`/`failed(_)`/
  `:not_applicable`-probe each advance; exhausted set → `{:terminal, :failed}`; serial
  one-at-a-time emission; passe_partout `*` floor reached last.
- **Probe directive:** a `can_process`-capable untried candidate → `{:query_can_process}`;
  `:applicable` probe fact → `{:run}`; `:not_applicable` probe fact → advance.
- **Extract fan-out:** all applicable extract stages emitted together; empty when capture
  straddled the semantic content.
- **Process DAG:** desired artifacts derived per component from `classification_desired`;
  backward frontier on paths to unmet goals only; straddle pre-satisfaction prunes a path.
- **Probe-first ordering:** mixed frontier emits `{:query_can_process}` before `{:run}`.
- **Conflict resolution / escalation:** same-output competing producers (first `produced`
  wins); different-output independent producers (both run).
- **Terminal tiers:** every row of §8, including the category split on the
  no-extraction tier.
- **Reopen on missing outcome:** a node with no outcome for the relevant
  `(stage_id, component_id)` — whether never-run or invalidated upstream — reappears in the
  frontier, while nodes with valid outcomes do not re-run.
- **Determinism:** the same `(catalog, facts)` yields the same decision.

## 11. Open questions carried forward

- **Probe-result persistence** — the durable home (a lightweight row vs. reusing the
  outcome channel). *(Phase 4.)*
- **`facts` source** — projected from the DB index, from disk, or both. *(Phase 3.)*
- **Invalidation operation** — the prune transform, trigger (CLI shape, batch scope), and
  cascade semantics. *(Phase 4/8.)*
- **Multiple same-type components** — index-discriminator scheme; blocked by the current
  `unique(snapshot_id, content_type)`. *(Phase 6, Part E.)*
