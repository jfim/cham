# Cham v2

Personal knowledge archiving system. Elixir/Phoenix monolith.

## Design Docs

Design specifications are in `design-docs/` (symlinked). Read them before working on a subsystem.
Implementation plans are in `docs/superpowers/plans/`.

## Parallel Agents

When dispatching parallel agents for this project, always pass `isolation: "worktree"` so each agent works on its own branch. Merge/rebase the resulting branches after they return. Do not run concurrent agents directly against the main working tree.

## Updating master

Never use `git update-ref` or `git branch -f` to move `master` — both skip the fast-forward check and can clobber commits, and `update-ref` with `HEAD` from `git -C <main-repo>` resolves against the main repo's checked-out branch (not your worktree). To advance master from a worktree: rebase your branch onto master, then `git push . HEAD:master`, which enforces a fast-forward and refuses if master is checked out elsewhere.

## Implementation

When executing an implementation plan from `docs/superpowers/plans/`, always use subagent-driven execution (one fresh subagent per task) via the `superpowers:subagent-driven-development` skill. Do not execute plans inline.

## Improvements / TODOs

Track future improvements, ideas, and TODOs in `/home/jfim/sync/Obsidian Personal/Personal/Projects/Active/Cham/Improvements.md`. When you discover something worth doing later (missing smoke test coverage, deferred UI polish, known tech debt, etc.), append it there rather than leaving scattered TODOs in code.

## Tech Stack

- Elixir 1.19+, OTP 28+
- Phoenix 1.7+ with LiveView
- Oban for background job processing
- PostgreSQL 16+
- Python 3.11+ scripts via uv

## Commands

- `mix test` — run unit tests
- `mix test --only integration` — run integration tests (may need network, uv, etc.)
- `mix format` — format code (sole formatting authority)
- `mix phx.server` — start dev server at http://localhost:4000

## Coding Conventions

- Follow standard Elixir community conventions
- `mix format` is the sole authority on code formatting — no Credo or other linters
- Prefer stdlib and OTP over adding libraries
- Phoenix, Ecto, and Oban are the core framework dependencies
- Unit tests run without external dependencies (no network, no GPU, no Ollama)
- Integration tests tagged `@moduletag :integration`

## Architecture

- Filesystem archive is the source of truth, PostgreSQL is a rebuildable index
- Subsystems communicate via Event Bus (Phoenix.PubSub wrapper), not direct calls
- Config is runtime-mutable via TOML file (`config/cham.toml`)
- Processing pipeline is a DAG of stages, built from desired artifacts
- Plugins implement `Cham.Plugin` behaviour and provide pipeline stages

## Key Modules

- `Cham.EventBus` — pub/sub with dual-topic broadcasting
- `Cham.Config.Manager` — TOML-based config with schema validation
- `Cham.Config.Schema` — config field type validation and defaults
- `Cham.Config.TomlEncoder` — serializes config maps to TOML format
