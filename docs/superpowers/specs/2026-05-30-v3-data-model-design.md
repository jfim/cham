# v3 Core Data Model — Design

**Date:** 2026-05-30
**Status:** Design / spec. Conceptual model only. Physical layout (on-disk
structure and DB schema) is deliberately deferred to a separate design (§9).
Companion to the ingestion-rework spec (`2026-05-29-ingestion-rework-design.md`),
which is the *control plane*; this spec is the *data model* that control plane
operates over.

## 1. Motivation and Scope

The ingestion-rework spec separated the pipeline into a pure logical layer, a
projection, and an executor, but explicitly deferred a cluster of **data-model**
concerns: one URL yielding multiple representations, typed links/edges between
items, discovery/re-seeding, re-archiving/snapshots, and URL-insufficiency as a
natural key. `design-docs/changes-for-v3.md` sketches an items/snapshots/edges
model and marks capture provenance as "idea, not designed."

This spec finalizes the **core data model**: the entities, their identity, the
relationships between them, capture provenance, and how all of that flows through
the ingestion control plane. It is the conceptual contract; the physical
realization (archive directory layout, Postgres schema) is a separate design.

### In scope

- The entity model: Item, Snapshot, Component, Artifact.
- URL identity as a hash set (the natural key).
- Typed edges between items.
- Capture provenance (origin of a capture).
- Discovery semantics (how ingesting one item spawns related items).
- How the model rides the ingestion control plane.

### Out of scope (own specs)

- Physical archive layout and Postgres schema (§9).
- Per-user data split (`users/<user_id>/` subtree), per-user vs. item-level tags.
- Typed-artifact on-disk contracts (manifests, `archived_html` layout, embeddings
  format).
- Display transforms (link rewriting, "Cham it").
- The detailed extractor↔executor↔enqueue interaction for discovery (control-plane
  concern; this spec defines *what* flows, not the mechanism).

## 2. Entity Model

v2 modeled an item as a single capture. v3 separates a stable handle from the
captures beneath it, and from the content extracted out of each capture. Four
nested entities:

```
Item        — a stable handle for one logical resource (identity = URL hash set)
 └─ Snapshot  — one top-level capture at a point in time (immutable)
     └─ Component — a distinct unit of primary content extracted from that capture
         └─ Artifact — outputs (capture bytes / extracted content / derived enrichment)
```

Plus **Edges**: directed, typed relationships *between Items*.

### 2.1 Item

- A stable handle for one logical resource. **One URL → one Item.**
- Identity is a **URL hash set** (§3), not a single URL.
- Carries capture-invariant shared metadata (canonical title hint, source,
  item-level tags) and its outbound edges.
- Has a status driven by the ingestion control plane (`bootstrapping`,
  `archived`, `complete`, `incomplete`, `failed`).

### 2.2 Snapshot

- One **top-level capture** at a point in time. Owns the raw capture bytes (WARC
  plus the self-contained assets passe-partout pulled in to make the capture
  whole).
- **Immutable.** An Item accumulates Snapshots over time (re-archiving an article
  months later).
- **Every capture writes a new Snapshot** — no byte-level dedup. Byte-identical
  content is effectively impossible (WARC timestamps alone differ), so dedup at
  that level would never fire. Content-equivalence dedup (for federation) is a
  separate, deferred concern operating at the extracted-content level, not raw
  bytes.

### 2.3 Component

- A distinct unit of **primary content** extracted from a Snapshot's bytes: the
  post body, the comment thread, the document, the video. Multiple per Snapshot.
- Produced by extract-phase stages (the ingestion spec's "eager fan-out": all
  applicable extractors run; each returns `produced` or `not_applicable`).
- A Component's identity is its **content type**, drawn from the existing
  vocabulary (`article`, `video`, `document`, `audio`, `podcast`, `pdf`, …),
  rather than an opaque id. In practice one component per type per snapshot; if a
  snapshot ever holds two of the same type they carry an index discriminator.

### 2.4 Artifact

Refines the ingestion spec's three artifact **categories**, now placed in the
hierarchy:

- **capture** — raw bytes obtained from outside. Belongs to the **Snapshot**.
- **extracted** — the semantic content of a Component. *Is* the Component's
  content (article text, the canonical video, pdf text).
- **derived** — enrichment (summary, transcript, embeddings, tags).

Whether a `derived` artifact belongs to a single Component or is shared at the
Item/Snapshot level is an **open question** (§10) — e.g. an item-level summary
spanning all components vs. a per-component summary.

### 2.5 The fetch-boundary rule (Item vs. Component)

The decision "is this a Component of the current Item, or a separate Item?" is
mechanical and tracks fetch behavior:

> Everything extractable from the bytes of a **single top-level capture** is a
> **Component** of that Snapshot. Anything that requires a **new top-level fetch**
> is a **separate Item**, joined by an Edge.

Page sub-resources passe-partout pulls in to make a capture self-contained (CSS,
images, fonts, a video poster) are part of *that* capture — not Components, not
separate Items. "New Item" means a new top-level capture request.

A consequence, intentionally embraced: the boundary tracks fetch behavior
honestly. A video embedded in a Reddit post that the capture *did* download is in
this Snapshot; one it *didn't* (autoplay off) becomes its own Item the moment it
is captured — because that requires a new fetch.

Worked example (a Reddit post):

- Self-post (text body + comments): **one** Item, one Snapshot, two Components
  (`article` body, comment thread) — both came from the one fetch.
- Link post: **one** reddit Item (comment-thread Component) **+ a separate Item**
  for the linked article (its own fetch), joined by a `linked` edge.
- Video post (external video, e.g. YouTube): reddit Item (comment thread) **+ a
  separate video Item**, joined by an `embed` edge.

## 3. Identity

An Item's natural key is a **URL hash set**, not a single URL.

- A submitted URL is **normalized** (documented, versioned rules) and hashed; the
  hash joins the Item's set.
- **Redirects accrue aliases**: submit A → redirects to B → both
  `normalize(A)` and `normalize(B)` are hashed into the set.
- **Lookup is hash-set intersection.** If an incoming URL's hash hits an existing
  Item's set, it is the *same* Item (→ a new Snapshot), not a new Item. Two Items
  never share a hash.
- This is both the in-instance natural key *and* the seed for federation, where
  two peers' Items match if their hash sets intersect.

### 3.1 Normalization

Normalization strips a **denylist of known tracking parameters** (`utm_*` and
other common trackers) and the fragment, and **preserves everything else** in the
query string. Stripping the whole query is wrong: `google.com/?q=potato` with the
query removed would collapse to a different page. The denylist is **versioned** so
it can grow without retroactively breaking existing hashes (a normalization
version bump is a deliberate, separate operation).

## 4. Edges

Directed, typed relationships **between Items**, emitted by extraction for a
page's **primary referents only**. Whether a page *has* primary referents is the
extractor's decision, per content type: a link-aggregator extractor (Reddit,
Slashdot, HN) emits an edge for what it points at; an article extractor emits no
edges by default (inline body links are display-transform territory, not edges).

### 4.1 Edge types

Stored in one canonical (outbound) direction; the inverse is derived for display.
Each type carries a **default capture policy** for its target, overridable by
per-source/domain config.

| Stored type | Inverse (display) | Default capture policy | Example |
|---|---|---|---|
| `embed`  | `embedded_in` | auto-capture target | reddit post → its embedded video |
| `linked` | `linked_from` | do not auto-capture  | aggregator post → the article it links to (and discussion-about, which is just a link) |
| `mirror` | `mirror_of` (symmetric) | do not auto-capture | crosspost / duplicate of the same content |

`comments_on`/`references` from earlier drafts collapse into `linked` — "a
discussion is effectively a reference."

### 4.2 Edge targets are URL-identities

An edge targets a **URL identity (hash)**, which resolves to an Item only if and
when that URL is captured. A `linked` referent that policy does not auto-capture
is simply a **dangling edge to a URL** — no Item exists for it yet, and none is
required. Resolution (hash → Item) is a join that may be empty (un-captured) or
hit (captured). This keeps edges portable and federation-ready, and sidesteps the
need for a "stub Item" entity in the core model.

Whether to ever materialize placeholder ("stub") Item rows for un-captured edge
targets is **deferred** (§10).

### 4.3 Edge provenance

An edge records *who created it*: an extractor stage (the common case), or a user
/ API (manual relating). Edges are otherwise the same regardless of source.

## 5. Capture Provenance

**Provenance lives on the Snapshot** — each capture has exactly one origin, and
re-captures of the same Item may have different origins. Nothing is duplicated at
the Item level.

Provenance is **orthogonal to edges**: an edge says how two Items *relate*;
provenance says how *this capture was triggered*. A video embedded in a Reddit
post (Snapshot origin `discovery`) that you *also* later submit by CLI gets a
second Snapshot with origin `cli`; both the `embed` edge and the two provenances
coexist.

Conceptual shape:

```
provenance: {
  kind:  cli | chrome_extension | subscription | rest_api | web_ui
       | integration | discovery | peer_fetch(future)
  actor: <user_id>          # null in single-user; the multi-user seam
  ref:   { … }              # kind-specific reference, e.g.
                            #   {subscription_id} | {integration_id}
                            #   {parent_item_id, edge_type}   ← kind = discovery
  agent: "cham-cli/1.2"     # freeform tool + version string
  captured_at: <timestamp>
}
```

Use cases this serves (from `changes-for-v3.md`): audit/filtering ("items I added
from Chrome this week"), debugging unexpected captures, quality signals, and
federation replay. Provenance is **available in `facts`** but `plan` does **not**
branch on it in v3 — quality-signal-driven default treatment is a future hook, not
a v3 behavior.

## 6. Discovery

Discovery is how ingesting one Item produces related Items. It is modeled as an
**extract outcome**, with spawning as an **executor side-effect** — preserving the
ingestion spec's pure-`plan` contract.

- A link-aggregator extractor does **not** create Items (that would break `plan`
  purity). It emits, as part of its outcome, the discovered referent(s):
  `{edge_type, target_url}`.
- The **executor**, on recording that outcome:
  1. records the edge (keyed by target URL-identity, §4.2);
  2. consults the edge-type default capture policy + per-source override and,
     for `embed`-type (or override-enabled) targets, **enqueues a capture** of the
     target URL — which begins that target Item's own plan loop.
- The parent's `plan` stays pure: it sees "extract produced Component X + edges Y"
  in `facts` and proceeds.

This is the ingestion spec's deferred "discovery / re-seeding with per-source rule
control," now given its shape. The **detailed** extractor↔executor↔enqueue
interaction (how referents are carried in the outcome record, how the executor
dedups concurrent discovery of the same URL) is a **control-plane concern, out of
scope here** (§1).

## 7. Interaction with the Ingestion Control Plane

How the entities surface in the pure `plan(config, facts)` loop:

1. **One plan loop per Item.** `facts` are projected per-Item from that Item's
   durable outcomes. Discovered Items, once captured, run their own loop.

2. **Components are classification.** `facts` carry, for the current Snapshot,
   which Components exist (= which extractors produced an `extracted` artifact) and
   the `derived` artifacts present per Component. The Item's content type *is the
   set of Component types* — the ingestion spec's "classification is a result of
   extraction." Desired artifacts are computed per Component-type inside `plan`.

3. **Snapshots reuse the archive handshake**, per-Snapshot: capture stages reach
   terminal → `plan` returns `{:archive}` → executor promotes + sets `archived` →
   re-invokes `plan` → extract/process run against the permanent location.

4. **The permanent slug derives from the first *extraction*'s title**, not from
   capture. This needs reconciling with the ingestion spec's capture-time archive
   handshake (which used `slugify(url)` as a floor so promotion could happen right
   after capture). The reconciliation — promote-then-rename vs. delay-promotion-
   until-first-extraction — is a physical-layout/control-plane decision and is
   resolved in the deferred physical-layout design (§9), not here. The data-model
   commitment is only: **slug ← title ← first extraction.**

5. **Provenance is stamped by the executor** at Snapshot creation, since only it
   knows the trigger. For `discovery`, `ref = {parent_item_id, edge_type}`.

## 8. Re-operations

Two distinct "re-" operations, kept cleanly separate:

- **Re-capture** = a **new Snapshot** (a fresh top-level fetch).
- **Re-derive** = **version-invalidation within a Snapshot** (the ingestion
  spec's mechanism: bump a stage version, run the invalidation query, the frontier
  reopens for exactly those nodes, reusing upstream artifacts on disk).

## 9. Deferred to Other Designs

- **Physical layout** — on-disk archive directory structure and the Postgres
  schema (tables, columns, indexes, how edges/identities/provenance are stored and
  rebuilt). Its own design.
- **Per-user data split** — `users/<user_id>/` subtree, per-user vs. item-level
  tags, annotations, read state, chats.
- **Typed-artifact contracts** — per-type on-disk manifests (`archived_html`,
  embeddings format) and the `pgvector` mirror for similarity search.
- **Display transforms** — link rewriting, resource resolution, "Cham it."
- **Discovery mechanism** — the precise extractor↔executor↔enqueue protocol (§6).
- **Slug-timing reconciliation** — promote-then-rename vs. delay promotion (§7.4).

## 10. Open Questions

- **Artifact ownership: per-Component vs. shared.** Do all `derived` artifacts
  hang off a single Component, or can some be Item/Snapshot-level (e.g. a summary
  spanning all Components of an item)? (§2.4)
- **Stub Items.** Whether to ever materialize placeholder Item rows for
  un-captured edge targets, or always keep them as dangling URL-identity edges
  (§4.2). Current lean: dangling edges, no stub entity.
- **Snapshot-pinned edges.** Edges target Items (latest-relevant Snapshot
  surfaced by default). Optional snapshot-pinning ("this comment thread refers to
  *that* version of the article") is deferred.
- **Normalization rule set.** The exact tracking-param denylist and the canonical
  normalization (host casing, query-param ordering, trailing slash) need to be
  enumerated when the physical layout is designed.
- **Multiple same-type Components.** The index-discriminator scheme for two
  Components of the same content type in one Snapshot (§2.3) is sketched, not
  specified.
