# MCP Server for Cham

Date: 2026-05-25
Status: Approved (brainstorm)

## Goal

Expose Cham's archived articles to MCP-capable assistants (Claude Code, Claude Desktop) so the user can ask the assistant to fetch the markdown of an article and discuss it. First cut ships two tools: `get_article_markdown` and `search_articles`.

## Non-goals

- Listing recent items, fetching metadata-only, or browsing tags (deferred — additive later).
- Non-article content types (PDF body, video transcripts, audio).
- MCP `resources` and `prompts` capabilities.
- A separate token type for MCP — reuse the existing REST API bearer token.

## Architecture

Add [`anubis_mcp`](https://hex.pm/packages/anubis_mcp) as a dependency. Mount its `Anubis.Server.Transport.StreamableHTTP.Plug` at `/mcp` in `ChamWeb.Router`, behind an auth plug that reuses the existing API bearer-token check. The MCP server module starts under the Cham supervision tree alongside the Phoenix endpoint.

```
ChamWeb.Router  ──forward "/mcp" (auth)──>  Anubis.StreamableHTTP.Plug  ──>  Cham.MCP.Server
                                                                                  │
                                                                                  ├── Cham.MCP.Tools.GetArticleMarkdown
                                                                                  └── Cham.MCP.Tools.SearchArticles
```

Claude Code connects as a remote MCP server, e.g.:

```json
{
  "mcpServers": {
    "cham": {
      "url": "http://localhost:4000/mcp",
      "headers": { "Authorization": "Bearer <api_key>" }
    }
  }
}
```

## New modules

### `Cham.MCP.Server`

```elixir
defmodule Cham.MCP.Server do
  use Anubis.Server,
    name: "cham",
    version: "0.1.0",
    capabilities: [:tools]

  component Cham.MCP.Tools.GetArticleMarkdown
  component Cham.MCP.Tools.SearchArticles

  @impl true
  def init(_client_info, frame), do: {:ok, frame}
end
```

Added to `Cham.Application` children: `{Cham.MCP.Server, transport: :streamable_http}`.

### `Cham.MCP.Tools.GetArticleMarkdown`

`use Anubis.Server.Component, type: :tool`.

Schema:

- `id` — string, required. Slug or UUID (full or ≥4-char prefix).

Behavior:

1. `Cham.Items.get_item_by_slug_or_id(id)` → item or `{:error, :not_found | :ambiguous}`.
2. Reject if `item.content_type != "article"` (`:not_an_article`).
3. Reject if `item.status not in [:complete, :incomplete]` (`:not_ready`).
4. `Cham.Items.read_primary_markdown(item)` → `{:ok, body} | {:error, :not_found}`.
5. Reply with `Response.tool() |> Response.text(body)`. Prepend a one-line header so the model has framing context:

   ```
   # <title>
   Source: <url>

   <body>
   ```

Errors map to `is_error: true` MCP responses with human-readable text (e.g. `"No item found for id 'xyz'"`, `"Item is still processing"`).

### `Cham.MCP.Tools.SearchArticles`

Schema:

- `query` — string, required.
- `limit` — integer, default `10`, max `50`.

Behavior:

1. `Cham.Items.list_items_paginated([search: query, content_type: "article"], limit: limit)` (matches the existing `list_items_paginated(filters \\ [], opts \\ [])` signature).
2. Map each item to a compact map: `id`, `slug`, `title`, `url`, `tags`, `inserted_at`.
3. Reply with JSON-encoded list as the text content. The model calls `get_article_markdown` for the chosen one.

Returning only metadata (no bodies) keeps responses small.

### `ChamWeb.Plugs.MCPAuth`

Thin wrapper around the existing REST API bearer-token check. If a single auth plug already exists, reuse it directly in `pipe_through` for the `/mcp` forward and skip this module.

## Shared content resolver

The "which markdown file represents this article" logic currently lives in `ChamWeb.DashboardLive.DetailHelpers.resolve_primary_content/3` and consults `display.content_order` (default `["cleaned_content", "content"]`). Extract it to the items context:

```elixir
# lib/cham/items.ex
def read_primary_markdown(%Item{} = item)
  :: {:ok, binary()} | {:error, :not_ready | :not_found}
```

It reads `Cham.Config.Manager.read_all("display").content_order`, walks the artifacts in that order, and returns the first file body it can read. The LiveView is refactored to call this helper for its article-content path, so MCP and the web UI stay consistent.

## Router

```elixir
# lib/cham_web/router.ex
scope "/mcp" do
  pipe_through :mcp_api  # bearer-token check, json transport
  forward "/", Anubis.Server.Transport.StreamableHTTP.Plug, server: Cham.MCP.Server
end
```

## Testing

Unit:

- `Cham.Items.read_primary_markdown/1` — cleaned present; only `content.md` present; neither present (item still processing); item complete with no artifacts (`:not_found`).
- `Cham.MCP.Tools.GetArticleMarkdown.execute/2` — happy path with a fixture item and tmp archive; not-found; ambiguous prefix; non-article content type; still-processing item.
- `Cham.MCP.Tools.SearchArticles.execute/2` — returns the expected compact maps and respects `limit`.

Integration (`@moduletag :integration`):

- Boot the Phoenix endpoint, send an MCP `tools/call` for `get_article_markdown` with a valid bearer token, assert the body comes back.
- Same call without `Authorization` → 401.

## Out-of-scope follow-ups

Tracked in the Cham Improvements file, not this spec:

- `list_recent_articles`, `get_article_metadata` tools.
- PDF / transcript content tools.
- MCP `resources` (exposing items as URI-addressable resources) once Claude clients use them more.
