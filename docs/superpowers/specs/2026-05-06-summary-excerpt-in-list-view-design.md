# Summary excerpt in list view

## Problem

The dashboard list view (everything except the video and document card grids) renders a row with title, badges, and an optional one-line excerpt sourced from `item.metadata["excerpt"]`. That key is populated only by the article extraction script, so video and audio rows render with no body text and feel bare.

When `summarize_ollama` runs successfully it produces a `summary.md` artifact, but nothing in the list view reads it. Reading the file per row at render time would mean N filesystem reads per page, so we want the excerpt cached on the item.

## Design

### Producer: `lib/cham/plugins/summarize_ollama.ex`

After a successful LLM summary, derive a one-line plain-text excerpt and return it in `item_metadata` so the orchestrator merges it into `item.metadata`.

- Strip Markdown: headings (`#`), list markers (`-`, `*`, `1.`), bold/italic markers (`**`, `*`, `_`), inline code backticks, fenced code blocks, link syntax (`[text](url)` → `text`), HTML tags.
- Collapse whitespace (including newlines) to single spaces.
- Trim, then take the first 280 characters. Match the article excerpt length from `scripts/extract_article/main.py:123`.
- Key: `"summary_excerpt"`.

Apply in the success path only (`summarize_with_llm/5`). The skip-on-too-short path and error/snooze paths do not set the key — there is nothing useful to extract.

### Consumer: `lib/cham_web/live/dashboard_live.html.heex`

At line 209-214, replace the single-key lookup with a fallback:

```heex
<p
  :if={blurb = item.metadata["excerpt"] || item.metadata["summary_excerpt"]}
  class="row-excerpt"
>
  {blurb}
</p>
```

Article excerpt wins when present (it is closer to the source content). Summary excerpt fills in for video, audio, and any other type that has a summary but no article-extracted excerpt. Card grids (video, document) are untouched.

### Backfill

None. Items summarized before this change will not have `summary_excerpt`; they will look the same as today (bare row). New summaries fill in the field. The user adds enough new items that the gap closes naturally.

## Testing

- Unit test for the markdown-stripping helper covering: headings, lists, bold/italic, inline code, fenced code, links, and multiple paragraphs collapsing into one line.
- Unit test that the truncation is at 280 chars (no mid-word concerns required — match the article script's behavior).
- Integration-style test for `summarize_ollama` that the success path returns `item_metadata: %{"summary_excerpt" => ...}`. The plugin's existing tests already mock `Cham.LLM.Provider.generate/3`; extend one of those.
- Skip path test: word_count < 50 returns `item_metadata: %{}` (unchanged).

No view test needed — the template change is a one-line fallback.
