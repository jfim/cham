# Passe-Partout capture stage — design

**Date:** 2026-06-01
**Status:** approved (brainstormed in dialogue → ready for implementation plan)
**Builds on:**
- [v3 data model](2026-05-30-v3-data-model-design.md)
- [v3 physical layout](2026-05-30-v3-physical-layout-design.md)
- [WARC page-view](2026-05-31-warc-page-view-design.md) — the primary consumer
- ytdlp-branch prototype — `lib/cham/plugins/passe_partout_download_url.ex` (browser-drive logic to carry over)

## 1. Purpose

Replace the generic HTTP fallback downloader with a browser-based **capture stage**.
It drives a real Chromium tab through the passe-partout REST API and produces, for
an HTML page, a range-extractable **`capture.warc.gz`** plus a SURT-sorted
**`capture.cdxj`** index; for a direct binary, a raw **`capture.<ext>`** file.

This stage is the **producer** for consumers already specified elsewhere: the
page-view `render_webpage` stage, the WARC resource endpoint, and `download_images`'
WARC cache. It resolves the two questions the page-view spec left open (§4/§9 there):
**who builds the CDXJ index** (this stage) and **what WARC compression** is used
(per-record/multi-member gzip, so a single record is range-extractable).

`generic_download_url` is **retired** — the plugin and its tests are deleted.
passe-partout becomes a **hard dependency**: if it is unreachable, capture errors and
Oban retries. There is no HTTP fallback.

## 2. Stage shape & placement

- New plugin `Cham.Plugins.PassePartoutCapture`, stage id `passe_partout_capture`,
  **capture phase**, snapshot-level.
- Output dir: `snapshots/<ts>/capture/stages/passe_partout_capture-<ts>/`.
- The Elixir browser-drive logic is carried over verbatim from the ytdlp-branch
  prototype (`passe_partout_download_url.ex`): create tab → fixed settle delay →
  scroll-to-bottom bursts (to trigger lazy-load) → network-idle wait → capture →
  delete tab (in an `after` block). Same passe-partout endpoints, same config knobs.
- The prototype's behavior of also writing a post-render `original.html`
  `initial_download` artifact is **dropped**: in v3, capture is WARC-only and the
  HTML/article is produced by extraction stages reading the WARC.

## 3. Control flow — two branches, decided by passe-partout

After tab creation, branch on `tab["download"]`, exactly as the prototype does:

- **HTML page** (no download): `GET /tabs/:id/warc` with the capture-completeness
  query (`rendered=1&domsnapshot=1&dom_rects=1&paint_order=1&computed_styles=<list>`)
  → an **uncompressed** `original.warc` written to a temp path → run the `warc_index`
  script (§5) → `capture.warc.gz` + `capture.cdxj`. The uncompressed intermediate is
  deleted afterward.
- **Direct binary** (download present): wait for the download to finish, enforce the
  size cap, stream the bytes → `capture.<ext>` (extension from content-type/URL).
  **No WARC, no CDXJ** — a one-record WARC of a file download adds no value.

## 4. Artifacts & on-disk layout

```
capture/stages/passe_partout_capture-<ts>/
  # HTML page:
  capture.warc.gz             # per-record (multi-member) gzip — range-extractable
  capture.cdxj                # SURT-sorted; one line per response record
  artifact.json               # category=capture; emits redirect chain + URL hashes
  passe_partout_capture.log
  # OR, direct binary:
  capture.<ext>               # raw bytes (e.g. capture.pdf)
  artifact.json               # category=capture; content_type label; no cdxj
```

**`capture.cdxj` is a second filename on the WARC artifact**, not its own artifact:
the two are always produced together and consumed together, so one capture artifact
carrying `["capture.warc.gz", "capture.cdxj"]` keeps them coupled.

Labels (page case): `{origin: original, type: capture, format: warc}`.
Labels (binary case): `{origin: original, type: capture, content_type: <mime>}`.

## 5. The `warc_index` script (recompress + index)

`scripts/warc_index/main.py`, run via `ScriptRunner.run_script_sync("warc_index",
[in_warc, out_warc_gz, out_cdxj], log_to: …)`. uv/PEP-723 inline deps: `warcio` +
`cdxj-indexer`. Steps:

1. `warcio recompress <in_warc> <out_warc_gz>` — rewrites each record as its own gzip
   member (the range-extractable form the page-view spec requires).
2. `cdxj-indexer <out_warc_gz>` → CDXJ with fields `{url, mime, status, digest,
   length, offset, filename}`, offsets pointing at each record's gzip member in the
   `.gz`. This matches the page-view §4 schema verbatim.
3. **Sort the CDXJ by SURT key** (`LC_ALL=C` byte sort on the leading key field)
   before writing `out_cdxj`. cdxj-indexer emits in WARC/record order, **not** sorted
   (verified), and the resource endpoint binary-searches the index — so the sort is
   **mandatory**.

Non-zero exit ⇒ stage error (retryable).

**Conversion-record handling (verified empirically on a 361-record passe-partout
WARC):**

- `warcio recompress` **preserves all records**, including passe-partout's two
  `conversion` records — the `warc-rendered-targets-1.0` HAR and the
  `urn:passe-partout:warc:dom-snapshot:1.0` CSSOM dump (both `application/json`). No
  errors.
- `cdxj-indexer` **indexes only `response`/`resource`/`revisit` records**; it
  **silently skips** the conversion records (and `request`/`warcinfo`). So even though
  both conversion records share the page's `WARC-Target-URI`, the index has **exactly
  one** line for the page's SURT key — the `text/html` 200 response. No key collision.

**Consequence for `render_webpage` (page-view spec):** the conversion records it needs
are **not in the CDXJ**. `render_webpage` must locate them by **streaming the WARC and
matching `WARC-Type: conversion` / `WARC-Profile`**, never via the index. This is the
intended division of labor: CDXJ indexes servable response resources; conversion
records are consumed by streaming.

## 6. Config

Carried over from the prototype under config key `plugins.passe_partout_capture`:
`base_url`, `auth_token`, `timeout`, `max_body_size`, `download_poll_interval`,
`download_max_wait`, `wait_network_idle`, `wait_timeout`, `capture_delay`,
`scroll_burst_wait`, `scroll_max_bursts`. The `computed_styles` list and the
`rendered/domsnapshot/dom_rects/paint_order` flags remain capture-completeness knobs,
defaulting to the prototype's values.

## 7. Graph data into `artifact.json`

The capture stage emits the **redirect chain** (initial URL → `tab["final_url"]`) and
the **URL hash-set** identity data into its `artifact.json`, per the v3 data-model and
physical-layout specs. The exact field schema is **owned by those specs** and deferred
to the v3 build — referenced here, not re-specified.

## 8. Failure handling & dependencies

- **Hard dependency on passe-partout.** Unreachable/down ⇒ stage errors, Oban retries
  (`max_attempts: 3`). No HTTP fallback; `generic_download_url` is deleted.
- **SURT contract.** CDXJ keys use the IA SURT canonicalization from cdxj-indexer's
  `surt` package. The page-view resource endpoint must SURT-canonicalize identically;
  that contract is owned by the page-view spec, noted here as the producing side.
- **Header honesty (page-view §6) — resolved.** passe-partout now renames
  `content-encoding`/`transfer-encoding` → `x-orig-*` and recomputes `Content-Length`,
  so WARC bodies are internally consistent. `warcio recompress` preserves headers
  as-is, which is now correct. No Cham-side fixup is needed.

## 9. Out of scope / open

- `render_webpage`, the WARC resource endpoint, and the UI toggle — all the page-view
  spec, not here.
- Capture completeness (paywall/consent/scroll/CSSOM/Shadow-DOM) — passe-partout's
  domain.
- Exact `artifact.json` URL-hash / redirect-chain schema — pinned by the v3 data-model
  spec (§7).
- On-disk stage-dir naming detail (`passe_partout_capture-<ts>` vs the page-view spec's
  illustrative `passe_partout-<ts>`) — align during implementation.
