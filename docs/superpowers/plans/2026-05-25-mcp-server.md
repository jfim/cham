# MCP Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose Cham's archived articles to MCP clients (Claude Code, Desktop) via two tools — `get_article_markdown` and `search_articles` — served over streamable HTTP at `/mcp`.

**Architecture:** Add the `anubis_mcp` hex dependency. Define one server module (`Cham.MCP.Server`) and two tool components. Mount Anubis's streamable-HTTP plug at `/mcp` in the Phoenix router (no auth — matches REST API). Extract the article-markdown resolution from the LiveView into `Cham.Items.read_primary_markdown/1` so the web UI and the MCP tool share one code path.

**Tech Stack:** Elixir 1.19, Phoenix 1.7, `anubis_mcp` (latest), ExUnit.

Spec: [docs/superpowers/specs/2026-05-25-mcp-server-design.md](../specs/2026-05-25-mcp-server-design.md)

**Deviation from spec:** The spec calls for reusing the REST API bearer token. Implementation review found the REST API has no bearer-token check today, so this plan mounts `/mcp` with no auth (consistent with `/api/v1`). Auth is deferred to the future REST API auth design and tracked in Task 14.

---

## File Map

**Create:**
- `lib/cham/mcp/server.ex` — Anubis server module, registers tool components.
- `lib/cham/mcp/tools/get_article_markdown.ex` — tool component.
- `lib/cham/mcp/tools/search_articles.ex` — tool component.
- `test/cham/items_primary_markdown_test.exs` — unit tests for the new resolver.
- `test/cham/mcp/tools/get_article_markdown_test.exs` — tool unit tests.
- `test/cham/mcp/tools/search_articles_test.exs` — tool unit tests.
- `test/cham_web/mcp_endpoint_test.exs` — `@moduletag :integration` end-to-end test.

**Modify:**
- `mix.exs` — add `{:anubis_mcp, "~> 0.16"}` (use whatever's current; see Task 1 for verification).
- `lib/cham/items.ex` — add `read_primary_markdown/1`.
- `lib/cham_web/live/dashboard_live/detail_helpers.ex` — make `resolve_article_content/3` delegate to the new helper for the content body (keep state/error semantics in the LiveView).
- `lib/cham/application.ex` — add `Cham.MCP.Server` to the supervision tree.
- `lib/cham_web/router.ex` — forward `/mcp` to the Anubis plug.

---

## Task 1: Add anubis_mcp dependency

**Files:**
- Modify: `mix.exs`

- [ ] **Step 1: Look up the current anubis_mcp version**

Run: `mix hex.info anubis_mcp`
Expected: output lists the latest stable release. Note the major.minor (e.g. `0.16.x`).

- [ ] **Step 2: Add the dep**

Edit `mix.exs` in the `defp deps do` list. After the `{:earmark, "~> 1.4"},` line add:

```elixir
      {:anubis_mcp, "~> <MAJOR.MINOR from step 1>"},
```

- [ ] **Step 3: Fetch and compile**

Run: `mix deps.get && mix compile`
Expected: compiles cleanly; `anubis_mcp` appears in `mix.lock`.

- [ ] **Step 4: Commit**

```bash
git add mix.exs mix.lock
git commit -m "deps: add anubis_mcp for MCP server"
```

---

## Task 2: `Cham.Items.read_primary_markdown/1` — failing test

**Files:**
- Create: `test/cham/items_primary_markdown_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Cham.ItemsPrimaryMarkdownTest do
  use Cham.DataCase, async: true

  alias Cham.Items

  setup do
    tmp = Path.join(System.tmp_dir!(), "cham-pm-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  defp insert_article(tmp, status \\ "complete") do
    {:ok, item} =
      Items.create_item(%{
        url: "https://example.com/#{System.unique_integer([:positive])}",
        content_type: "article",
        status: status,
        archive_path: tmp,
        title: "T"
      })

    item
  end

  defp write_artifact!(item, type, origin, filename, body) do
    stage_dir = Path.join(item.archive_path, type)
    File.mkdir_p!(stage_dir)
    File.write!(Path.join(stage_dir, filename), body)

    {:ok, _} =
      Items.upsert_artifact(item.id, %{
        path: type,
        filenames: [filename],
        labels: %{"type" => type, "origin" => origin},
        status: "produced"
      })
  end

  test "returns cleaned_content body when present", %{tmp: tmp} do
    item = insert_article(tmp)
    write_artifact!(item, "cleaned_content", "derived", "cleaned_content.md", "CLEANED")
    write_artifact!(item, "content", "derived", "content.md", "RAW")
    assert {:ok, "CLEANED"} = Items.read_primary_markdown(item)
  end

  test "falls back to content when cleaned_content missing", %{tmp: tmp} do
    item = insert_article(tmp)
    write_artifact!(item, "content", "derived", "content.md", "RAW")
    assert {:ok, "RAW"} = Items.read_primary_markdown(item)
  end

  test "returns :not_found when no markdown artifacts exist", %{tmp: tmp} do
    item = insert_article(tmp)
    assert {:error, :not_found} = Items.read_primary_markdown(item)
  end

  test "returns :not_ready when item is still processing", %{tmp: tmp} do
    item = insert_article(tmp, "processing")
    assert {:error, :not_ready} = Items.read_primary_markdown(item)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/cham/items_primary_markdown_test.exs`
Expected: FAIL — `function Cham.Items.read_primary_markdown/1 is undefined`.

  If `Items.create_item/1` or `Items.upsert_artifact/2` don't exist with those exact signatures, open `lib/cham/items.ex` and adjust the test to call whichever creation functions the context exposes. Do not change the assertions.

---

## Task 3: Implement `read_primary_markdown/1`

**Files:**
- Modify: `lib/cham/items.ex`

- [ ] **Step 1: Add the function**

Open `lib/cham/items.ex`. Add (place near the other artifact-reading helpers, e.g. just below `read_artifact_content/2` around line 289):

```elixir
  @doc """
  Read the primary article markdown for an item, honoring the
  `display.content_order` config (default `["cleaned_content", "content"]`).
  For each type, derived artifacts are preferred over original.
  """
  def read_primary_markdown(%Item{} = item) do
    cond do
      item.content_type != "article" ->
        {:error, :not_found}

      item.status not in ["complete", "incomplete"] ->
        {:error, :not_ready}

      true ->
        artifacts = list_artifacts(item.id)
        do_read_primary_markdown(item, artifacts, content_order())
    end
  end

  defp do_read_primary_markdown(_item, _artifacts, []), do: {:error, :not_found}

  defp do_read_primary_markdown(item, artifacts, [type | rest]) do
    case find_and_read(item, artifacts, type, "derived") do
      {:ok, body} ->
        {:ok, body}

      :miss ->
        case find_and_read(item, artifacts, type, "original") do
          {:ok, body} -> {:ok, body}
          :miss -> do_read_primary_markdown(item, artifacts, rest)
        end
    end
  end

  defp find_and_read(item, artifacts, type, origin) do
    artifact =
      Enum.find(artifacts, fn a ->
        a.labels["type"] == type and a.labels["origin"] == origin and
          a.status == "produced"
      end)

    case artifact && read_artifact_content(item, artifact) do
      {:ok, body} -> {:ok, body}
      _ -> :miss
    end
  end

  defp content_order do
    case Cham.Config.Manager.read_all("display") do
      {:ok, %{content_order: s}} when is_binary(s) and s != "" ->
        s |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

      _ ->
        ["cleaned_content", "content"]
    end
  end
```

- [ ] **Step 2: Run tests**

Run: `mix test test/cham/items_primary_markdown_test.exs`
Expected: PASS (all 4 tests).

- [ ] **Step 3: Run the full unit suite**

Run: `mix test`
Expected: PASS — no regressions.

- [ ] **Step 4: Commit**

```bash
git add lib/cham/items.ex test/cham/items_primary_markdown_test.exs
git commit -m "feat(items): add read_primary_markdown/1 shared resolver"
```

---

## Task 4: Refactor LiveView to use the shared resolver

**Files:**
- Modify: `lib/cham_web/live/dashboard_live/detail_helpers.ex`

- [ ] **Step 1: Confirm the LiveView's existing tests pass before changing it**

Run: `mix test test/cham_web/live`
Expected: PASS (or note pre-existing failures so you can distinguish later).

- [ ] **Step 2: Replace `resolve_article_content/3` body**

In `lib/cham_web/live/dashboard_live/detail_helpers.ex` around line 182, replace the function body so the "available" case delegates to the shared resolver. Keep the processing/failed/not_requested branches because the LiveView still needs HTML and stage-state info.

```elixir
  defp resolve_article_content(item, artifacts, stage_history) do
    case Items.read_primary_markdown(item) do
      {:ok, content} ->
        %{state: :available, content: content, html: md_to_html(content), error: nil}

      {:error, _} ->
        types = content_order()
        try_content_types(item, artifacts, stage_history, types, nil)
    end
  end
```

Leave `try_content_types/5`, `content_order/0`, and `resolve_artifact_content/5` in place — they handle the processing/failed/not_requested fallbacks the resolver doesn't cover.

- [ ] **Step 3: Run LiveView tests**

Run: `mix test test/cham_web/live`
Expected: PASS (same set as step 1).

- [ ] **Step 4: Commit**

```bash
git add lib/cham_web/live/dashboard_live/detail_helpers.ex
git commit -m "refactor(live): use Items.read_primary_markdown in detail view"
```

---

## Task 5: `Cham.MCP.Server` skeleton

**Files:**
- Create: `lib/cham/mcp/server.ex`

- [ ] **Step 1: Write the server module**

```elixir
defmodule Cham.MCP.Server do
  @moduledoc "Cham's MCP server. Exposes archived articles to MCP-capable clients."

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

- [ ] **Step 2: Verify it compiles (tool modules don't exist yet, so expect a compile error)**

Run: `mix compile`
Expected: FAIL — references to `Cham.MCP.Tools.GetArticleMarkdown` and `Cham.MCP.Tools.SearchArticles` are undefined. That's expected; the next tasks add them.

---

## Task 6: `get_article_markdown` tool — failing test

**Files:**
- Create: `test/cham/mcp/tools/get_article_markdown_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Cham.MCP.Tools.GetArticleMarkdownTest do
  use Cham.DataCase, async: true

  alias Cham.MCP.Tools.GetArticleMarkdown
  alias Cham.Items

  setup do
    tmp = Path.join(System.tmp_dir!(), "cham-mcp-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  defp seed_article(tmp, body) do
    {:ok, item} =
      Items.create_item(%{
        url: "https://example.com/#{System.unique_integer([:positive])}",
        content_type: "article",
        status: "complete",
        archive_path: tmp,
        title: "Hello",
        slug: "hello-#{System.unique_integer([:positive])}"
      })

    stage_dir = Path.join(tmp, "content")
    File.mkdir_p!(stage_dir)
    File.write!(Path.join(stage_dir, "content.md"), body)

    {:ok, _} =
      Items.upsert_artifact(item.id, %{
        path: "content",
        filenames: ["content.md"],
        labels: %{"type" => "content", "origin" => "derived"},
        status: "produced"
      })

    item
  end

  defp call(params) do
    GetArticleMarkdown.execute(params, %Anubis.Server.Frame{})
  end

  test "returns markdown body for slug", %{tmp: tmp} do
    item = seed_article(tmp, "# Hello\n\nbody")
    {:reply, response, _frame} = call(%{id: item.slug})
    refute response.is_error
    text = response.content |> hd() |> Map.fetch!(:text)
    assert text =~ "# Hello"
    assert text =~ "body"
    assert text =~ item.url
  end

  test "returns error for unknown id" do
    {:reply, response, _frame} = call(%{id: "nope-nope"})
    assert response.is_error
  end

  test "returns error for non-article item", %{tmp: tmp} do
    {:ok, item} =
      Items.create_item(%{
        url: "https://example.com/x-#{System.unique_integer([:positive])}",
        content_type: "video",
        status: "complete",
        archive_path: tmp,
        slug: "vid-#{System.unique_integer([:positive])}"
      })

    {:reply, response, _frame} = call(%{id: item.slug})
    assert response.is_error
  end

  test "returns error for still-processing item", %{tmp: tmp} do
    {:ok, item} =
      Items.create_item(%{
        url: "https://example.com/p-#{System.unique_integer([:positive])}",
        content_type: "article",
        status: "processing",
        archive_path: tmp,
        slug: "proc-#{System.unique_integer([:positive])}"
      })

    {:reply, response, _frame} = call(%{id: item.slug})
    assert response.is_error
  end
end
```

- [ ] **Step 2: Run test (expect compile failure)**

Run: `mix test test/cham/mcp/tools/get_article_markdown_test.exs`
Expected: FAIL — module `Cham.MCP.Tools.GetArticleMarkdown` is undefined.

---

## Task 7: Implement `get_article_markdown`

**Files:**
- Create: `lib/cham/mcp/tools/get_article_markdown.ex`

- [ ] **Step 1: Write the tool**

```elixir
defmodule Cham.MCP.Tools.GetArticleMarkdown do
  @moduledoc "Fetch the markdown body of an archived article by slug or UUID prefix."

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias Cham.Items

  schema do
    field(:id, :string,
      required: true,
      description: "Item slug or UUID (full or >=4-char prefix)"
    )
  end

  @impl true
  def execute(%{id: id}, frame) do
    with {:ok, item} <- Items.get_item_by_slug_or_id(id),
         :ok <- check_article(item),
         {:ok, body} <- Items.read_primary_markdown(item) do
      text = format(item, body)
      {:reply, Response.tool() |> Response.text(text), frame}
    else
      {:error, :not_found} ->
        {:reply, error("No item found for id #{inspect(id)}"), frame}

      {:error, :ambiguous} ->
        {:reply, error("Ambiguous id prefix #{inspect(id)} — provide more characters"), frame}

      {:error, :not_an_article} ->
        {:reply, error("Item #{inspect(id)} is not an article"), frame}

      {:error, :not_ready} ->
        {:reply, error("Item #{inspect(id)} is not ready yet (still processing)"), frame}
    end
  end

  defp check_article(%{content_type: "article"}), do: :ok
  defp check_article(_), do: {:error, :not_an_article}

  defp format(item, body) do
    """
    # #{item.title || "(untitled)"}
    Source: #{item.url}

    #{body}
    """
  end

  defp error(msg) do
    Response.tool() |> Response.error(msg)
  end
end
```

- [ ] **Step 2: Run the tool tests**

Run: `mix test test/cham/mcp/tools/get_article_markdown_test.exs`
Expected: PASS (all 4 tests).

  If `Response.error/1` has a different arity/name in the installed anubis_mcp version, run `mix help` or check `deps/anubis_mcp/lib/anubis/server/response.ex` and adjust the `error/1` helper accordingly (look for whatever function sets `is_error: true`).

- [ ] **Step 3: Commit**

```bash
git add lib/cham/mcp/server.ex lib/cham/mcp/tools/get_article_markdown.ex \
        test/cham/mcp/tools/get_article_markdown_test.exs
git commit -m "feat(mcp): add get_article_markdown tool"
```

---

## Task 8: `search_articles` tool — failing test

**Files:**
- Create: `test/cham/mcp/tools/search_articles_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Cham.MCP.Tools.SearchArticlesTest do
  use Cham.DataCase, async: true

  alias Cham.MCP.Tools.SearchArticles
  alias Cham.Items

  defp insert_article(title) do
    {:ok, item} =
      Items.create_item(%{
        url: "https://example.com/#{System.unique_integer([:positive])}",
        content_type: "article",
        status: "complete",
        title: title,
        slug: "s-#{System.unique_integer([:positive])}"
      })

    item
  end

  defp call(params) do
    SearchArticles.execute(params, %Anubis.Server.Frame{})
  end

  test "returns matching articles as JSON list" do
    a = insert_article("Bayesian methods for cats")
    _b = insert_article("Quantum dogs")

    {:reply, response, _frame} = call(%{query: "Bayesian", limit: 10})
    refute response.is_error
    text = response.content |> hd() |> Map.fetch!(:text)
    decoded = Jason.decode!(text)
    assert is_list(decoded)
    titles = Enum.map(decoded, & &1["title"])
    assert "Bayesian methods for cats" in titles
    refute "Quantum dogs" in titles

    [first | _] = decoded
    assert first["id"] == a.id
    assert first["slug"] == a.slug
    assert first["url"]
    assert Map.has_key?(first, "tags")
    assert Map.has_key?(first, "inserted_at")
    refute Map.has_key?(first, "content")
  end

  test "honors limit" do
    for i <- 1..5, do: insert_article("Common term #{i}")
    {:reply, response, _frame} = call(%{query: "Common", limit: 2})
    refute response.is_error
    decoded = response.content |> hd() |> Map.fetch!(:text) |> Jason.decode!()
    assert length(decoded) == 2
  end
end
```

- [ ] **Step 2: Run (expect failure)**

Run: `mix test test/cham/mcp/tools/search_articles_test.exs`
Expected: FAIL — `Cham.MCP.Tools.SearchArticles` undefined.

---

## Task 9: Implement `search_articles`

**Files:**
- Create: `lib/cham/mcp/tools/search_articles.ex`

- [ ] **Step 1: Write the tool**

```elixir
defmodule Cham.MCP.Tools.SearchArticles do
  @moduledoc "Search archived articles by title/url/excerpt. Returns metadata only."

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias Cham.Items

  schema do
    field(:query, :string, required: true, description: "Search term")
    field(:limit, :integer, default: 10, description: "Max results (capped at 50)")
  end

  @impl true
  def execute(%{query: query} = params, frame) do
    limit = params |> Map.get(:limit, 10) |> clamp(1, 50)

    %{entries: items} =
      Items.list_items_paginated(
        [search: query, content_type: "article"],
        limit: limit
      )

    payload = Enum.map(items, &compact/1)
    {:reply, Response.tool() |> Response.text(Jason.encode!(payload)), frame}
  end

  defp clamp(n, lo, hi) when is_integer(n), do: n |> max(lo) |> min(hi)
  defp clamp(_, lo, _), do: lo

  defp compact(item) do
    %{
      id: item.id,
      slug: item.slug,
      title: item.title,
      url: item.url,
      tags: item.tags || [],
      inserted_at: item.inserted_at && DateTime.to_iso8601(item.inserted_at)
    }
  end
end
```

  If `list_items_paginated/2` returns a different shape than `%{entries: [...]}` (check `lib/cham/items.ex` around line 131), adjust the pattern match accordingly. Don't change the response format.

- [ ] **Step 2: Run tool tests**

Run: `mix test test/cham/mcp/tools/search_articles_test.exs`
Expected: PASS.

- [ ] **Step 3: Run full suite**

Run: `mix test`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add lib/cham/mcp/tools/search_articles.ex \
        test/cham/mcp/tools/search_articles_test.exs
git commit -m "feat(mcp): add search_articles tool"
```

---

## Task 10: Wire server into supervision tree

**Files:**
- Modify: `lib/cham/application.ex`

- [ ] **Step 1: Add MCP server child**

In `lib/cham/application.ex` `start/2`, add `{Cham.MCP.Server, transport: :streamable_http}` to the `children` list. Place it just before `ChamWeb.Endpoint`:

```elixir
      Cham.Pipeline.Supervisor,
      {Cham.MCP.Server, transport: :streamable_http},
      # Start to serve requests, typically the last entry
      ChamWeb.Endpoint
```

- [ ] **Step 2: Boot the app**

Run: `mix compile`
Expected: clean compile.

Run: `iex -S mix` — wait for the prompt, then `:init.stop()` (or Ctrl+C twice).
Expected: app boots without errors; no crash from the MCP server child.

- [ ] **Step 3: Commit**

```bash
git add lib/cham/application.ex
git commit -m "feat(mcp): start Cham.MCP.Server under supervision"
```

---

## Task 11: Mount `/mcp` in the router

**Files:**
- Modify: `lib/cham_web/router.ex`

- [ ] **Step 1: Add the forward**

In `lib/cham_web/router.ex`, after the existing `scope "/", ChamWeb do ... pipe_through :api ... get "/health" ... end` block (around line 46), add:

```elixir
  scope "/mcp" do
    pipe_through :api
    forward "/", Anubis.Server.Transport.StreamableHTTP.Plug, server: Cham.MCP.Server
  end
```

- [ ] **Step 2: Compile**

Run: `mix compile`
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add lib/cham_web/router.ex
git commit -m "feat(mcp): mount streamable HTTP transport at /mcp"
```

---

## Task 12: Integration test — end-to-end `tools/call`

**Files:**
- Create: `test/cham_web/mcp_endpoint_test.exs`

- [ ] **Step 1: Write the test**

```elixir
defmodule ChamWeb.MCPEndpointTest do
  use ChamWeb.ConnCase, async: false
  @moduletag :integration

  alias Cham.Items

  setup do
    tmp = Path.join(System.tmp_dir!(), "cham-mcp-int-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  defp seed(tmp) do
    {:ok, item} =
      Items.create_item(%{
        url: "https://example.com/int-#{System.unique_integer([:positive])}",
        content_type: "article",
        status: "complete",
        archive_path: tmp,
        title: "Integration",
        slug: "int-#{System.unique_integer([:positive])}"
      })

    stage = Path.join(tmp, "content")
    File.mkdir_p!(stage)
    File.write!(Path.join(stage, "content.md"), "INT-BODY")

    {:ok, _} =
      Items.upsert_artifact(item.id, %{
        path: "content",
        filenames: ["content.md"],
        labels: %{"type" => "content", "origin" => "derived"},
        status: "produced"
      })

    item
  end

  test "tools/call get_article_markdown returns the body", %{conn: conn, tmp: tmp} do
    item = seed(tmp)

    body = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{
        "name" => "get_article_markdown",
        "arguments" => %{"id" => item.slug}
      }
    }

    resp =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> post("/mcp", Jason.encode!(body))

    assert resp.status == 200
    text = resp.resp_body
    assert text =~ "INT-BODY"
    assert text =~ item.url
  end
end
```

- [ ] **Step 2: Run**

Run: `mix test test/cham_web/mcp_endpoint_test.exs --include integration`
Expected: PASS.

  Streamable HTTP responses may be SSE-framed. If the assertion fails because the body is wrapped (e.g. `data: {...}\n\n`), keep the substring assertions — the markdown body and URL will still appear in the payload. If status is 406 or 415, add/remove the `accept` header until the plug accepts the request (check `deps/anubis_mcp/lib/anubis/server/transport/streamable_http/plug.ex` for the accepted content types).

- [ ] **Step 3: Commit**

```bash
git add test/cham_web/mcp_endpoint_test.exs
git commit -m "test(mcp): integration test for /mcp tools/call"
```

---

## Task 13: Manual smoke from Claude Code

**Files:** none

- [ ] **Step 1: Start the dev server**

Run: `mix phx.server`
Expected: listens on `http://localhost:4000`.

- [ ] **Step 2: Register the MCP server with Claude Code**

In another terminal:

```bash
claude mcp add --transport http cham http://localhost:4000/mcp
```

- [ ] **Step 3: Verify discovery**

Run: `claude mcp list`
Expected: `cham` listed; tools `get_article_markdown` and `search_articles` appear.

- [ ] **Step 4: Try a call**

In a Claude Code session, ask: "Use cham/search_articles to find an article about <topic you've archived>, then fetch its markdown."
Expected: search returns matching items, then get_article_markdown returns the body.

- [ ] **Step 5: Commit any tweaks (if needed) and stop**

If steps 1–4 surfaced any bug fixes, commit them with a `fix(mcp): ...` message. Otherwise nothing to commit.

---

## Task 14: Note follow-ups in the Improvements file

**Files:**
- Modify: `/home/jfim/sync/Obsidian Personal/Personal/Projects/Active/Cham/Improvements.md`

- [ ] **Step 1: Append a short MCP section**

Append to that file:

```markdown
## MCP server

- Add `list_recent_articles(limit)` and `get_article_metadata(id)` tools.
- Add tools for PDF/transcript bodies (non-article content types).
- Expose items as MCP `resources` once Claude clients use them more.
- Add bearer-token auth once the REST API auth design lands (covers both surfaces).
```

- [ ] **Step 2: No commit** — Obsidian vault is outside the repo.

---

## Verification checklist

- [ ] `mix test` is green.
- [ ] `mix test --only integration` includes the new `/mcp` integration test and passes.
- [ ] `mix format --check-formatted` passes.
- [ ] Manual smoke (Task 13) returned an article body through Claude Code.
