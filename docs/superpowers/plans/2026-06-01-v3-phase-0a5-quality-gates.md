# v3 Phase 0a.5 — Quality Gates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Establish the standing code-quality gate after the v2 teardown — add `sobelow`, give `dialyzer` cached PLTs, do one cleanup pass over the surviving core so `just check` is green, and add GitHub Actions CI that runs the gate on every push/PR.

**Architecture:** Runs **after Plan 0a** (`docs/superpowers/plans/2026-06-01-v3-phase-0a-teardown-and-schema.md`), which leaves a small compiling core (config, event bus, Oban wiring, repo, subscriptions context + RSS backend, MCP server shell, the six `Cham.Archive.*` schemas, Phoenix shell, `ConfigLive`/`SubscriptionIndexLive`/`HealthController`) with `mix test` green. The repo already has `credo` + `dialyxir` as deps, a configured `.credo.exs`, and a `justfile` whose `check` recipe runs `fmt-check → compile → credo → dialyzer → test`. This plan adds the two missing pieces (`sobelow`, dialyzer PLT caching), splits the `just` recipes so dialyzer can be a separate non-blocking CI job, cleans the surviving core to green, wires GitHub Actions, and makes `CLAUDE.md` honest about linters. From Phase 0b onward the gate is CI-blocking.

**Tech Stack:** Elixir 1.19 / OTP 28 (`.tool-versions`: erlang 28.4.1, elixir 1.19.5-otp-28), Phoenix 1.7, PostgreSQL 16, `credo`, `dialyxir`, `sobelow`, GitHub Actions (`erlef/setup-beam`).

**Reconciliation:** `docs/superpowers/specs/2026-06-01-v3-ingestion-reconciliation-and-sequencing.md` (Part C "Quality gates land after the teardown"; critical path `0a → 0a.5 → 0b → …`).

---

## Preconditions (verify before starting)

- [ ] **Step 0: Confirm the post-0a baseline**

Run: `just check 2>&1 | tail -30` (or `mix compile --warnings-as-errors && mix test`)
Expected: the repo compiles and `mix test` passes. The v2 ingestion layer is gone (`git grep -nE "Cham\.(Items|Pipeline|Plugin|Plugins|Chat|JobTracking\.Tracker)\b" lib` → no matches). If 0a has not been run yet, **stop** — this plan depends on it.

> Note: `just check` may currently *fail* at the `dialyzer` step (no cached PLT) or pass — either is fine; this plan makes it reliably green. The hard precondition is only "compiles + tests pass".

---

## Task 1: Add `sobelow` dependency

**Files:**
- Modify: `mix.exs:38-74` (the `deps/0` list)

- [ ] **Step 1: Add the dep**

In `mix.exs`, add `sobelow` to the `deps/0` list, right after the `dialyxir` line:

```elixir
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false}
```

- [ ] **Step 2: Fetch it**

Run: `mix deps.get`
Expected: `sobelow` is resolved and added to `mix.lock`.

- [ ] **Step 3: Verify sobelow runs and surfaces a non-zero exit on findings**

Run: `mix sobelow --exit low; echo "exit=$?"`
Expected: sobelow prints a scan summary for the surviving web surface (`lib/cham_web/`). `exit=0` if clean, non-zero if it found something. Either is acceptable here — real findings are triaged in Task 4. We only need to confirm the task runs.

- [ ] **Step 4: Commit**

```bash
git add mix.exs mix.lock
git commit -m "build(v3): add sobelow security scanner to the quality gate"
```

---

## Task 2: Give dialyzer cached PLTs

Without configured PLT paths, `mix dialyzer` rebuilds the core PLT every run and CI can't cache it. This adds stable on-disk PLT paths under `priv/plts/` (git-ignored, cached in CI) and an ignore file for curated false positives.

**Files:**
- Modify: `mix.exs:4-19` (the `project/0` keyword list)
- Modify: `.gitignore`
- Create: `.dialyzer_ignore.exs`

- [ ] **Step 1: Add the `:dialyzer` config to `project/0`**

In `mix.exs`, add a `dialyzer:` key to the keyword list returned by `project/0`, after the `aliases: aliases(),` line:

```elixir
      aliases: aliases(),
      dialyzer: [
        plt_local_path: "priv/plts/local.plt",
        plt_core_path: "priv/plts/core.plt",
        plt_add_apps: [:mix, :ex_unit],
        ignore_warnings: ".dialyzer_ignore.exs",
        list_unused_filters: true
      ],
      deps: deps(),
```

- [ ] **Step 2: Ignore the PLT directory**

Append to `.gitignore`:

```
# Dialyzer PLTs (cached, not committed)
/priv/plts/
```

- [ ] **Step 3: Create the (empty) ignore file**

Create `.dialyzer_ignore.exs`:

```elixir
# Curated dialyzer false positives. Each entry is one of:
#   {"path/to/file.ex", "warning substring"}  |  {"path/to/file.ex"}  |  ~r/regex/
# Keep this empty unless a warning is a genuine false positive — fix real ones.
[]
```

- [ ] **Step 4: Build the PLT**

Run: `mkdir -p priv/plts && mix dialyzer --plt`
Expected: PLT build runs (slow the first time — minutes) and writes `priv/plts/core.plt` + `priv/plts/local.plt`. Confirm with `ls priv/plts`.

- [ ] **Step 5: Run dialyzer**

Run: `mix dialyzer`
Expected: completes using the cached PLT. It may report warnings on the surviving core — those are fixed in Task 4. Confirm the PLT is reused (no full rebuild).

- [ ] **Step 6: Commit**

```bash
git add mix.exs .gitignore .dialyzer_ignore.exs
git commit -m "build(v3): configure cached dialyzer PLTs + ignore file"
```

---

## Task 3: Split the `just` recipes (add sobelow; isolate dialyzer)

So CI can run the fast checks as a blocking job and dialyzer as a separate (initially non-blocking) job, split the recipe into `check-fast` (everything but dialyzer) and `check` (adds dialyzer). Local `just check` still runs the whole gate.

**Files:**
- Modify: `justfile:24-42`

- [ ] **Step 1: Add a `sobelow` recipe and split `check`**

Replace the tail of `justfile` (from the `credo` recipe onward) with:

```just
# Run credo (linter)
credo:
    mix credo --strict

# Run sobelow (security scan)
sobelow:
    mix sobelow --exit low

# Run dialyzer (static analysis)
dialyzer:
    mix dialyzer

# Run tests
test:
    mix test

# Run the Phoenix server
server:
    iex -S mix phx.server

# Fast checks — everything except dialyzer (mirrored by the CI `check` job)
check-fast: fmt-check compile credo sobelow test

# Run all checks (CI equivalent)
check: check-fast dialyzer
```

- [ ] **Step 2: Verify the recipes resolve**

Run: `just --list`
Expected: `check-fast`, `sobelow`, and `check` all appear; no parse error.

- [ ] **Step 3: Commit**

```bash
git add justfile
git commit -m "build(v3): split just check into check-fast + dialyzer; add sobelow recipe"
```

---

## Task 4: Cleanup pass — make `just check` green

This is a triage loop, not a scripted edit: run the gate, read each tool's output, and bring the **surviving core** to clean. The surface is small, so this is bounded. Done condition: `just check` exits 0.

**Files:** whatever the tools flag under `lib/` and `test/` (surviving core only — 0a already deleted the v2 code).

- [ ] **Step 1: Format**

Run: `mix format && git diff --stat`
Expected: `mix format` is the sole formatting authority; commit any reformatting it does.

- [ ] **Step 2: Compile clean**

Run: `mix compile --warnings-as-errors`
Expected: PASS. Fix any warning by editing the offending code (unused vars, deprecations). If a warning names a module 0a should have removed, remove the dead reference.

- [ ] **Step 3: Credo**

Run: `mix credo --strict`
Expected: 0 issues. For each finding, **prefer fixing the code**. Only if a check is genuinely inapplicable to this codebase, disable it in `.credo.exs` with a one-line comment explaining why — do not blanket-lower `strict`.

- [ ] **Step 4: Sobelow**

Run: `mix sobelow --exit low`
Expected: exit 0. For a genuine false positive (e.g. a deliberately-permissive config), generate a config to suppress it: `mix sobelow --save-config` writes `.sobelow-conf`; add the specific finding id to its `:ignore` list with a comment. Fix real findings in code. Commit `.sobelow-conf` only if you created one.

- [ ] **Step 5: Dialyzer**

Run: `mix dialyzer`
Expected: "done (passed successfully)". Fix real type issues in code. Add an entry to `.dialyzer_ignore.exs` **only** for a confirmed false positive (e.g. a known Ecto/Phoenix macro-expansion warning), with a comment.

- [ ] **Step 6: Tests**

Run: `mix test`
Expected: PASS (no regressions from the cleanup edits).

- [ ] **Step 7: Whole gate green**

Run: `just check`
Expected: every step green, exit 0.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "chore(v3): clean surviving core to a green quality gate"
```

---

## Task 5: GitHub Actions CI

A blocking `check` job (format, compile, credo, sobelow, test against a Postgres service) mirroring `just check-fast`, plus a separate `dialyzer` job that caches the PLT and is **non-blocking** (`continue-on-error: true`) until the cache proves stable.

**Files:**
- Create: `.github/workflows/ci.yml`

- [ ] **Step 1: Write the workflow**

Create `.github/workflows/ci.yml`:

```yaml
name: CI

on:
  push:
    branches: [master]
  pull_request:

permissions:
  contents: read

jobs:
  check:
    name: Format / compile / credo / sobelow / test
    runs-on: ubuntu-latest
    env:
      MIX_ENV: test
    services:
      postgres:
        image: postgres:16
        env:
          POSTGRES_USER: postgres
          POSTGRES_PASSWORD: postgres
          POSTGRES_DB: postgres
        ports:
          - 5432:5432
        options: >-
          --health-cmd "pg_isready -U postgres"
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5
    steps:
      - uses: actions/checkout@v4

      - uses: erlef/setup-beam@v1
        with:
          version-file: .tool-versions
          version-type: strict

      - name: Cache deps and _build
        uses: actions/cache@v4
        with:
          path: |
            deps
            _build
          key: ${{ runner.os }}-mix-test-${{ hashFiles('**/mix.lock') }}
          restore-keys: ${{ runner.os }}-mix-test-

      - run: mix deps.get
      - run: mix deps.compile

      # Mirrors `just check-fast`.
      - run: mix format --check-formatted
      - run: mix compile --warnings-as-errors
      - run: mix credo --strict
      - run: mix sobelow --exit low
      - run: mix test

  dialyzer:
    name: Dialyzer (non-blocking until PLT cache is stable)
    runs-on: ubuntu-latest
    # TODO(0c+): once this job is green on two consecutive runs with a warm PLT
    # cache, remove continue-on-error to make dialyzer a blocking gate.
    continue-on-error: true
    env:
      MIX_ENV: dev
    steps:
      - uses: actions/checkout@v4

      - uses: erlef/setup-beam@v1
        with:
          version-file: .tool-versions
          version-type: strict

      - name: Cache deps and _build (dev)
        uses: actions/cache@v4
        with:
          path: |
            deps
            _build
          key: ${{ runner.os }}-mix-dev-${{ hashFiles('**/mix.lock') }}
          restore-keys: ${{ runner.os }}-mix-dev-

      - name: Cache dialyzer PLT
        uses: actions/cache@v4
        with:
          path: priv/plts
          key: ${{ runner.os }}-plt-${{ hashFiles('**/mix.lock') }}
          restore-keys: ${{ runner.os }}-plt-

      - run: mix deps.get
      - run: mkdir -p priv/plts && mix dialyzer --plt
      - run: mix dialyzer
```

- [ ] **Step 2: Validate YAML locally**

Run: `ruby -ryaml -e "YAML.load_file('.github/workflows/ci.yml')" 2>/dev/null && echo OK || python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/ci.yml')); print('OK')"`
Expected: `OK` (the workflow parses as valid YAML).

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "ci(v3): add GitHub Actions quality gate (check + non-blocking dialyzer)"
```

> CI runs on push. Verifying the run is green on GitHub is part of Task 7 (it happens the first time this branch is pushed); do not block this task on a remote run.

---

## Task 6: Make CLAUDE.md honest about linters

`CLAUDE.md` currently says "no Credo or other linters", which already contradicts the live `just check`. Update it to reflect the gate. `mix format` remains the sole *formatting* authority.

**Files:**
- Modify: `CLAUDE.md` (Commands + Coding Conventions sections)

- [ ] **Step 1: Update the Coding Conventions line**

Replace:

```markdown
- `mix format` is the sole authority on code formatting — no Credo or other linters
```

with:

```markdown
- `mix format` is the sole authority on *formatting*. Code-quality gates run via `just check` / CI: `credo --strict` (consistency/complexity), `dialyxir` (success typing), `sobelow` (Phoenix security). These lint and type-check; they never reformat — that stays `mix format`'s job.
```

- [ ] **Step 2: Add the gate to the Commands section**

After the line:

```markdown
- `mix format` — format code (sole formatting authority)
```

add:

```markdown
- `just check` — run the full quality gate (format check, compile, credo, sobelow, dialyzer, test)
```

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs(v3): document the quality gate in CLAUDE.md (supersede no-linters line)"
```

---

## Task 7: Final verification gate

**Files:** none (verification only)

- [ ] **Step 1: Whole gate green locally**

Run: `just check`
Expected: every step exits 0 — `fmt-check`, `compile`, `credo --strict`, `sobelow`, `test`, `dialyzer`.

- [ ] **Step 2: Confirm no stray linter config drift**

Run: `git status --porcelain`
Expected: clean (everything committed). `.sobelow-conf` is committed only if Task 4 created it; `priv/plts/` is git-ignored.

- [ ] **Step 3: Push and confirm CI**

Run: `git push` (push the working branch), then check the run: `gh run watch` or `gh run list --limit 1`.
Expected: the `check` job is green. The `dialyzer` job runs and is non-blocking (a failure there does not fail the workflow). Once dialyzer is green on two consecutive warm-cache runs, remove `continue-on-error` from `.github/workflows/ci.yml` to make it blocking.

---

## Done

After Task 7: the surviving core passes `mix format --check-formatted`, `mix compile --warnings-as-errors`, `credo --strict`, `sobelow`, `dialyzer`, and `mix test`; the gate is wired into GitHub Actions (dialyzer non-blocking pending a stable PLT cache); and `CLAUDE.md` describes it accurately. **Phase 0b** (`Cham.Identity`, `Cham.Archive.Layout`, `Cham.Archive` context primitives) and every later phase are built against this green gate.

## Self-review notes

- **Spec coverage:** Part C of the reconciliation doc asks for `mix format` check + sobelow + dialyxir + credo (Tasks 1–4), one cleanup pass over the surviving core (Task 4), CI-blocking from 0b with dialyzer starting non-blocking (Task 5, `continue-on-error`), and the CLAUDE.md supersession (Task 6). All covered.
- **Already-present, intentionally not re-added:** `credo`, `dialyxir`, `.credo.exs`, and the base `just` recipes exist pre-0a; this plan only adds the deltas (`sobelow`, dialyzer PLT config, recipe split, CI).
- **Open-ended by nature:** Task 4 ("fix what the tools flag") cannot enumerate findings in advance; it is bounded by the small surviving surface and has a hard done-condition (`just check` exits 0).
