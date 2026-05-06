# Cham

**Cham** (ចាំ, Khmer for *"remember"*) is a self-hosted personal knowledge archive. It sits between you and the web: capturing the articles, videos, podcasts, and PDFs you care about, transforming them into forms you can actually use, and preserving everything in a portable archive you own.

You encounter interesting content constantly, but consuming and retaining it is a different problem. Content disappears. Languages are barriers. Hour-long podcasts hide ten minutes of value. Your memory of *"that article about goldfish"* doesn't come with a bookmark.

Cham is the answer to that.

## What it does

- **Captures** web content via a browser extension — one click, or automatically when you've spent time reading something.
- **Transforms** content beyond simple archiving — summarizes articles, transcribes podcasts and videos, translates across languages, extracts text from PDFs.
- **Preserves** originals immutably alongside derived artifacts, so you always have the raw source.
- **Searches** by concept, time range, or content type — *"what did I read about goldfish last week?"*
- **Triages** subscriptions — skim a generated podcast summary to decide whether it deserves an hour of your time.
- **Detects changes** — re-archive a URL and see what's different since last time.

## Who it's for

Technical self-hosters who want to own their knowledge archive. People comfortable running Docker or Elixir on their own hardware. Cham is a personal tool, not a service — no accounts, no sharing, no public-facing components.

## What it isn't

- Not a read-later app — it processes and archives content, not just bookmarks it.
- Not a note-taking tool — it captures external content, not your thoughts (though it plays nicely with tools like Obsidian).
- Not a hosted service — self-hosted, private, no cloud dependency.

## Getting started

```bash
mix setup            # install deps, set up the database, build assets
mix phx.server       # http://localhost:4000
```

Python-based pipeline stages (whisper, article extraction, …) are managed via [uv](https://github.com/astral-sh/uv):

```bash
cd cli && uv sync
```

## Learn more

- [`design-docs/vision.md`](design-docs/vision.md) — the why
- [`design-docs/overview.md`](design-docs/overview.md) — the full design specification
- [`CLAUDE.md`](CLAUDE.md) — guidance for AI assistants working on the codebase

## License

TBD.
