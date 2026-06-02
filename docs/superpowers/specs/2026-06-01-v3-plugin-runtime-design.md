# v3 Plugin Runtime — Design (Phase 1)

**Date:** 2026-06-01
**Status:** Approved design (brainstormed 2026-06-01). Not built. Phase 1 of the v3
ingestion rework.

**Reconciliation:** `2026-06-01-v3-ingestion-reconciliation-and-sequencing.md` (Part D,
Phase 1 row + scope-expansion paragraph). This spec **reduces** the scope the
reconciliation doc reserved for Phase 1 — see §1.1; the reconciliation doc is updated to
match.

---

## 1. Scope

Phase 1 builds the **plugin runtime**: the unit that lets code — Elixir *or* an external
subprocess in any language — be registered, described, and invoked under one contract.
The v2 teardown (Plan 0a) removed the v2 plugin/stage system and nothing else rebuilds
one.

**In scope:**
- The plugin **manifest** (static declarative contract) + directory packaging + registry/discovery.
- The **wire protocol**: one-shot, `request.json` in / `output.json` out (via `working_dir`),
  with optional JSONL progress events streamed on stdout.
- Two **transports** sharing one contract: in-process Elixir (fast path) and external subprocess.
- The **`stage`** kind in full: typed I/O contract, the optional `can_process` probe, `perform`, the outcome taxonomy.
- The **`subscription`** kind's *invocation contract* (checkpoint round-trip), testable in isolation.
- Freezing the contracts that Phases 2/4 consume: the `{:query_can_process}` planner seam and artifact-type validation.

**Out of scope (deferred):** see §11. Notably: the `plan`/executor *implementations*
(Phases 2/4), the subscription **scheduler + checkpoint persistence + submit wiring**
(Phase 4/5, where the submit path exists), the `subscriber` and `integration` kinds
(reserved), `waiting_for_input` resume channels, and on-disk *typed layouts*.

### 1.1 Reductions vs. the reconciliation doc

The reconciliation doc reserved Phase 1 as "full kind × class" plus a `waiting_for_input`
**resume seam**. Two reductions were agreed during this design:

- **`waiting_for_input` is reserved, not built** (§5.4). The outcome name exists, but
  returning it fails the item as `:unsupported`. No resume request kind, no `waiting`
  lifecycle state (consistent with the locked status enum, reconciliation B2).
- **Only `stage` is fully built; `subscription` gets its invocation contract; `subscriber`
  and `integration` are reserved** (§6, §7). The full kind × class *contract* still exists
  (the manifest's `kind` field accepts all four), but unbuilt kinds have no invocation path.

The one genuinely folded-in seam that remains is the **typed-artifact contract** (§5.1).

---

## 2. Concepts

- **Plugin** — a registered unit identified by a manifest. Has a **kind** and a **class**.
- **Kind** ∈ `stage | subscription | subscriber | integration`. Kind determines *what the
  plugin is for* and the shape of its request/response. Phase 1 builds `stage` fully and
  `subscription`'s invocation contract; `subscriber`/`integration` are reserved.
- **Class** ∈ `in_process | subprocess`. Class determines only the **transport**. The
  contract (request/response shapes) is identical across class — "the wire protocol is
  canonical; in-process is a fast path."
- **Manifest** — the plugin's static, declarative self-description (§3). Host-held; the
  source of truth for everything *except* `can_process`, which is live logic the plugin
  runs (the "hybrid manifest" decision).
- **Artifact type** — a first-class, validated routing key for the typed I/O contract
  (§5.1). Rides inside the existing `artifacts.labels["type"]` field (no Phase 0 schema
  change). Its vocabulary is seeded in config and extended by plugin manifests.

---

## 3. The Manifest

### 3.1 Packaging (subprocess plugins)

Each external plugin is a **directory** under a configured plugins root (mirrors today's
`scripts/<name>/` convention), containing a `manifest.toml` and one or more executable
entrypoints:

```
plugins/
  extract_article/
    manifest.toml
    main.py
    check.py
```

In-process plugins are Elixir modules implementing a behaviour (§5, §8) and are listed at
compile time; they have no on-disk manifest — they supply the same fields via callbacks.

### 3.2 `manifest.toml` (stage example)

Manifests are **TOML** (matching cham's config convention; the *wire* is JSON).

```toml
id = "extract_article"
kind = "stage"            # stage | subscription | subscriber | integration
phase = "extract"         # bootstrap | extract | process   (stage only)
version = 3               # bump to invalidate prior artifacts (§5.6)
queue = "general"         # Oban queue (stage only)
max_attempts = 3          # same-tool retry budget (stage only)

# Typed I/O contract (§5.1). `type` is required; `labels` is an optional refinement filter.
inputs  = [ { type = "html_capture", labels = { origin = "original" } } ]
outputs = [ { type = "article_markdown", labels = { format = "text" } } ]

# New artifact types this plugin introduces into the validated vocabulary (§5.1).
declares_types = ["article_markdown"]

[entrypoints]
perform     = "uv run main.py"     # required
can_process = "python3 check.py"   # optional; presence advertises the cheap-probe capability (§5.2)

[config_schema]
# Field definitions registered into a Config.Manager namespace `plugins.<id>` (§8).
# Mirrors the existing Cham.Plugin config_field shape: key/type/default/description/required/options.
```

### 3.3 Validation

At registration the host validates: `kind` is known; `phase` is valid for a stage; every
declared input/output `type` is in the vocabulary (seeded ∪ all plugins' `declares_types`);
required entrypoints exist and are executable. A malformed manifest is **logged and
skipped**, never fatal to boot.

---

## 4. Wire Protocol

**One-shot per invocation.** The host writes the request to
**`working_dir/request.json`**, spawns the entrypoint with **`working_dir` as its sole
argument**, and reads a **JSONL event stream** from stdout until the process exits. (This
mirrors v2's `working_dir`-as-argument convention; the plugin just reads a file — trivial
in any language, no stdin/EOF plumbing — and the request stays on disk for debugging.)

- **`output.json` = the authoritative result.** The plugin writes
  `working_dir/output.json` (atomically: temp file + rename) containing the terminal
  result — the `outcome` + `artifacts`/`item_metadata`/`provenance` (or `{ "applicable":
  … }` for a probe; see §5–§6). The host deletes any pre-existing `output.json` before
  invoking, so a reused `working_dir` cannot yield a stale read.
- **stdout = optional JSONL progress events.** Each line is one JSON object with an
  `"event"` field; emitting any is optional (a plain bash plugin emits none). These are
  *not* the result — they are live progress, forwarded to the EventBus:
  - `{ "event": "status", "message": "Loading model" }`
  - `{ "event": "progress", "value": 80, "eta": "32s" }`
  - `{ "event": "log", "level": "warn", "message": "..." }`
- **stderr = raw logs** (non-protocol; captured to the stage's log file like v2).
- **Files cross via the shared `working_dir`** (the entrypoint's sole argument; holds
  `request.json`, the input artifacts, `output.json`, and the produced outputs) — never
  over the wire.
- **Completion/failure detection.** After the process exits the host reads `output.json`:
  present + valid → its `outcome` (including a plugin-*reported* `failed(category)`);
  **absent or unparseable → `failed(:error)`** — this catches OOM-kill, hard crashes, and
  bugs. The exit code refines the error *message*, but `output.json` presence is what's
  authoritative. Timeout is executor-owned (kill → `failed(:error)`).

**EventBus forwarding.** stdout `status`/`progress`/`log` events are republished on the
EventBus (UI/observability), exactly as v2's `ScriptRunner.run_async` publishes
`ScriptOutput`. They carry no result data — the result is read from `output.json` after
exit.

**In-process fast path.** An in-process Elixir plugin receives the **same request struct**
and an **`emit` function** (for `status`/`progress`/`log`), and **returns the result
struct** (the in-process equivalent of writing `output.json`) — no serialization, no
process, no files. The runtime dispatches to the in-process
or subprocess transport purely on the plugin's `class`; callers and `plan` never know
which.

**Daemonization is the plugin's private business.** Because invocation is one-shot and the
host is stateless, a plugin that wants to amortize startup (model loading) may fork its
own daemon on first call and have its entrypoint be a thin client to it. The host neither
knows nor manages this.

---

## 5. The `stage` Kind

A stage consumes input artifacts and produces output artifacts, participating in the
processing DAG. The DAG is **derived from labels/types, not wired**: a stage declares the
artifact *types* it consumes/produces, and edges fall out of `output type ↦ input type`
matching (§5.1). This preserves v2's label-dataflow model (OR = competing producers of the
same output type; AND = a stage needing two input types).

### 5.1 Typed I/O contract (the frozen seam)

- A stage's `inputs`/`outputs` are lists of `{ type, labels? }`. **`type`** is a name from
  a **validated vocabulary**; **`labels`** is an optional refinement filter (v2-style map).
- **Vocabulary** = a seeded set in config (`html_capture`, `article_markdown`, `audio`,
  `thumbnail`, `summary`, `tags`, …) **∪** every plugin's `declares_types`. The host
  rejects inputs/outputs naming an unknown type at registration, and rejects a `perform`
  result whose produced artifact carries a type the stage did not declare as an output.
- **Storage:** the type rides in the existing `artifacts.labels["type"]` field — **no
  Phase 0 schema change**. The contract treats it as first-class (validated); the database
  treats it as one more label key.
- **Deferred:** the *on-disk structure* of each type (which filenames, which formats) is
  **not** pinned here. The contract names the type; the bytes are a later concern.

### 5.2 The `can_process` probe (optional, separate entrypoint)

`can_process` answers the content-inspection question that labels/types cannot: "these
bytes are labeled `article` but it's a 10-word caption — not for me." Because that is a
*partial run*, it is an **optional, separate, lightweight entrypoint** so the probe need
not pay `perform`'s cost (e.g. `uv run` + CUDA/model load):

- A `[entrypoints].can_process` (or, in-process, an optional `can_process/1` callback)
  **advertises the cheap-probe capability**. Absent ⇒ no probe; the stage is route-and-run
  and `not_applicable` arrives post-hoc from `perform`.
- **Request (`request.json`):** `{ "request": "can_process", "item_id", "inputs": [{type, labels, filenames, input_path}] }`.
- **Result (`output.json`):** `{ "applicable": true | false }`. Binary — inputs are
  already determined by labels/types, so the probe only judges applicability.

### 5.3 `perform`

- **Request (`request.json`):** `{ "request": "perform", "item_id", "config": {…resolved plugin config…}, "inputs": [{type, labels, filenames, input_path}] }`.
- **Result (`output.json`, success):**
  ```json
  { "outcome": "produced",
    "artifacts": [ { "type": "article_markdown", "labels": { "format": "text" }, "filenames": ["content.md"] } ],
    "item_metadata": { "title": "…" },
    "provenance": { "tool": "readability-lxml" } }
  ```
  The plugin writes artifact files into `working_dir`; the result lists them by
  `{type, labels, filenames}`. `item_metadata` carries item-level facts (e.g. title — feeds
  re-slugify, reconciliation B3); `provenance` records how it was produced.

### 5.4 Outcome taxonomy

The `output.json` `outcome` is one of (the stage assigns it; §6 of ingestion-rework):

- **`produced`** — artifacts exist.
- **`not_applicable`** — "I looked; nothing here for me." Advances the candidate walk
  without burning the item.
- **`failed`** with a **`category`** from the closed set `:blocked | :unsupported |
  :bad_input | :error`. A plugin reports `:blocked`/`:unsupported`/`:bad_input` via
  `output.json`; the executor assigns `:error` itself when `output.json` is
  absent/unparseable (crash, OOM, timeout).
- **`waiting_for_input`** — **reserved**. Documented for a future phase (a stage needing a
  human: login wall, CAPTCHA, manual upload). In Phase 1, returning it makes the executor
  **fail the item as `:unsupported`** (recorded faithfully so logs distinguish it from a
  code-bug `:error`). No resume request kind; no `waiting` lifecycle state.

Transient retry ("network blip, retry the same tool") and snooze are **executor-owned**
and never recorded as outcomes / never reach `plan`.

### 5.5 The `plan`/executor seam (frozen here; implemented in Phases 2/4)

`plan` must stay **pure** (ingestion-rework §5). The probe is reconciled with purity by
making its result a **fact**, not an in-line call:

1. `plan` routes purely on the static manifest's typed I/O. For a candidate that advertises
   a `can_process` entrypoint and hasn't been probed, `plan` may emit a new directive
   **`{:query_can_process, [stage]}`** (alongside the existing `{:run, [stage]}` and
   `{:terminal, status}`).
2. The **executor** runs the probe (effectful) and records `applicable | not_applicable`
   as a fact.
3. `plan` re-runs and sees the fact: `applicable ⇒ {:run, [stage]}`; `not_applicable ⇒`
   advance the candidate walk (treated like a `not_applicable` outcome).

Phase 1 delivers the **mechanism** (the probe entrypoint + its request/response + the
capability flag) and **freezes** the directive name and the fact shape. The **policy**
(when `plan` probes) is Phase 2; the executor loop is Phase 4.

### 5.6 Versioning

`manifest.version` (int) is stamped onto each produced `artifacts.version`. Bumping it is
the invalidation trigger (ingestion-rework §10). Phase 1 only **stamps and surfaces** the
version; the invalidation *logic* is Phase 2/4.

---

## 6. The `subscription` Kind (invocation contract only)

A subscription is a **scheduled enumerator with an opaque checkpoint**: handed its last
checkpoint, it enumerates what exists and returns new items plus a fresh checkpoint. This
generalizes cham's existing `subscriptions` subsystem (the Elixir-only RSS
`BackendRegistry` backend) into a polyglot plugin kind. Plan 0a removed the v2
item-creating `poll_worker` with a note that it re-wires "to the v3 submit path in Phase
4/5" — that re-wire is where subscriptions reconnect.

**Built in Phase 1 (runtime concern):** the manifest (`kind = "subscription"`), the
one-shot invocation, and the checkpoint request/response — fully testable by invoking a
subscription plugin and asserting it returns items + a new checkpoint.

- **Request (`request.json`):** `{ "request": "perform", "subscription_id", "config": {…}, "checkpoint": <opaque|null> }`.
- **Result (`output.json`):**
  ```json
  { "items": [ { "url": "https://…", "metadata": { … } } ],
    "checkpoint": <opaque new value> }
  ```
- The **checkpoint is opaque to the host** — the plugin decides its meaning (timestamp,
  last GUID, etag, page cursor). The host stores it verbatim against the subscription and
  returns it next run.

**Deferred to Phase 4/5 (needs the submit path):** the Oban **scheduler**, checkpoint
**persistence**, and **submitting** returned items (item creation + URL-identity dedup).
Re-homing the existing RSS backend as an in-process subscription plugin happens then.

---

## 7. Reserved Kinds: `subscriber`, `integration`

The manifest parser and registry **accept** `kind = "subscriber"` and `kind =
"integration"`, but neither has an invocation path in Phase 1.

- **`subscriber`** — *event-driven* reaction to an EventBus event (e.g. on `item.completed`,
  sync to an Obsidian vault; webhooks; notifications). Built when the first real subscriber
  is designed (the EventBus→invocation dispatcher lands with its consumer).
- **`integration`** — an external-system bridge (reverse-index tables, outbound sync).
  Reserved for a later phase.

---

## 8. Registry & Discovery

At startup the runtime:

1. **Scans** the configured plugins root; parses each `manifest.toml`; **validates** (§3.3).
2. **Registers** in-process behaviour-modules from a compile-time list (`Cham.Plugin.Stage`
   for the stage kind; subscription's in-process behaviour exists for the kind's contract).
3. **Registers each plugin's `config_schema`** into a `Config.Manager` namespace
   `plugins.<id>` (reusing the existing config registration path).
4. Builds the in-memory **catalog** `plan` reads (per-stage typed I/O, phase, version,
   probe-capability flag) and the dispatch table (id → {class, kind, entrypoints/module}).

`cham.toml` **enables/disables** plugins and sets **escalation order** (the `[capture]
order` list and analogous orderings; reconciliation B5). A disabled plugin is parsed but
not added to the catalog.

The registry is the single boundary between "what plugins exist" and the rest of the
system; `plan` (Phase 2) consumes the catalog, the executor (Phase 4) consumes the
dispatch table.

---

## 9. Error Capture & Observability

- **stderr** is captured to the stage's log file (v2 parity).
- **Crashes / timeouts / OOM-kill** → no or unparseable `output.json` → `failed(:error)`;
  the executor owns the timeout (kill the process, like `ScriptRunner.kill_port`).
- **Progress** is visible live via the EventBus forwarding of `status`/`progress`/`log`
  events.

---

## 10. Testing Strategy

- **In-process stage:** a fake `Cham.Plugin.Stage` exercised through the registry +
  runtime for both request kinds (`can_process` → applicable/not_applicable; `perform` →
  produced / not_applicable / failed(category)); assert the `emit` callback streams events.
- **Subprocess stage:** a tiny real entrypoint (shell or Python) that reads `request.json`
  and writes `output.json` — proves request-file reading, optional stdout
  `status`/`progress` forwarding to the EventBus, `output.json` result parsing,
  `working_dir` file exchange, and **missing/garbage `output.json` → `failed(:error)`**
  (the crash/OOM path).
- **Subscription invocation:** a fake subscription plugin (both classes) returning
  `{items, checkpoint}`; assert the checkpoint round-trips (null in → value out → same
  value in next call).
- **Manifest validation:** unit tests for unknown kind, unknown/undeclared type, missing
  required entrypoint, malformed TOML (skipped, not fatal).
- **`waiting_for_input`:** a stage returning it maps to `failed(:unsupported)`.

---

## 11. Deferred / Out of Scope

- The `plan` and executor **implementations** (Phases 2/4) — Phase 1 only freezes the
  `{:query_can_process}` directive name and the probe-fact shape.
- The subscription **scheduler + checkpoint persistence + submit wiring** (Phase 4/5);
  re-homing the RSS backend.
- The **`subscriber`** dispatcher (EventBus bridge) and **`integration`** kind.
- **`waiting_for_input`** resume: the `resume` request kind, resume state model, `waiting`
  lifecycle state, and input channels (body upload, interactive UI).
- **On-disk typed layouts** — per-type filename/format schemas.
- **Host-managed long-lived workers** — plugins self-daemonize instead.

---

## 12. Open Questions

- **Plugins root location** — a single `plugins/` dir vs. bundled (`priv/plugins`) +
  user-supplied roots. *(Resolve when writing the plan.)*
- **Request/response struct names** and the exact in-process behaviour callback set
  (`manifest/0` vs. discrete callbacks). *(Plan-time detail.)*
- **`config` resolution timing** — does the executor resolve `plugins.<id>` config and
  inject it into the request, or does the plugin read config itself? (Leaning: executor
  injects, so external plugins need no config access.) *(Phase 4 touch-point; contract
  reserves the `config` request field now.)*
- **Per-type on-disk layout** — deferred, but the first extraction stages (Phase 6) will
  force the question.

---

## 13. Proposed Module Layout (for the plan)

- `Cham.Plugin.Manifest` — the parsed manifest struct + TOML parse/validate.
- `Cham.Plugin.ArtifactType` — vocabulary (seeded ∪ declared) + validation.
- `Cham.Plugin.Registry` — discovery scan, in-process module registration, config-schema
  registration, the catalog + dispatch table.
- `Cham.Plugin.Runtime` — invocation: writes `request.json`, dispatches by class, forwards
  stdout progress events to the EventBus, reads `output.json` after exit, returns the
  result (or `failed(:error)` when it's missing/unparseable).
- `Cham.Plugin.Transport.Subprocess` / `Cham.Plugin.Transport.InProcess` — the two
  transports behind one internal interface (reuse `ScriptRunner` port handling).
- `Cham.Plugin.WireProtocol` — request/response/event JSON encode/decode + struct defs.
- `Cham.Plugin.Stage` — the in-process stage behaviour. (`Cham.Plugin.Subscription`
  behaviour for the subscription kind's in-process contract.)
