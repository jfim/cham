# Phase 5: Web UI — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a LiveView web interface for browsing, submitting, and monitoring items in the Cham knowledge archive.

**Architecture:** Two independent LiveViews — `DashboardLive` (sidebar + item list with filters) and `ItemDetailLive` (full-width detail with processing view). Real-time updates via EventBus subscriptions. Filter state encoded in URL query params. Shared UI components for badges, item displays, and content rendering.

**Tech Stack:** Phoenix LiveView 1.0+, Tailwind CSS, Heroicons, CoreComponents (modal, forms, flash)

---

## File Structure

### New Files

| File | Responsibility |
|------|---------------|
| `lib/cham_web/components/ui_components.ex` | Shared UI: badges, tags, progress bars, timestamps, content states |
| `lib/cham_web/live/dashboard_live.ex` | Dashboard LiveView: sidebar, item list, filters, submit modal, real-time |
| `lib/cham_web/live/dashboard_live.html.heex` | Dashboard template |
| `lib/cham_web/live/item_detail_live.ex` | Item detail LiveView: content display, bottom pane, processing, real-time |
| `lib/cham_web/live/item_detail_live.html.heex` | Item detail template |
| `test/cham_web/live/dashboard_live_test.exs` | Dashboard LiveView tests |
| `test/cham_web/live/item_detail_live_test.exs` | Item detail LiveView tests |

### Modified Files

| File | Changes |
|------|---------|
| `lib/cham/items.ex` | Add query functions: filter by content_type/tag, count_by_content_type, count_by_tag, list_in_progress, read_artifact_content |
| `lib/cham_web/router.ex` | Add live routes for dashboard and item detail |
| `lib/cham_web/components/layouts/app.html.heex` | Replace Phoenix default header with Cham header |

### Parallelism

```
Task 1 (Items queries) ──┐
Task 2 (Layout + routes) ─┼── Task 4 (Dashboard) → Task 5 (Submit modal) → Task 6 (Dashboard real-time)
Task 3 (UI components) ──┘                                                        │
                                                                                   └── Task 7 (Item detail) → Task 8 (Item detail real-time)
```

Tasks 1, 2, 3 can run in parallel. Then 4, then 5+6, then 7, then 8.

---

## Task 1: Items Context Query Extensions

Add query functions needed by the web UI: filtering by content_type and tag, counting for facets, listing in-progress items, and reading artifact file content.

**Files:**
- Modify: `lib/cham/items.ex`
- Create: `test/cham/items_query_test.exs`

- [ ] **Step 1: Write failing tests for new query functions**

Create `test/cham/items_query_test.exs`:

```elixir
defmodule Cham.ItemsQueryTest do
  use Cham.DataCase

  alias Cham.Items

  setup do
    {:ok, article1} =
      Items.create_item(%{url: "https://example.com/article1", content_type: "article", tags: ["elixir", "phoenix"]})

    {:ok, article2} =
      Items.create_item(%{url: "https://example.com/article2", content_type: "article", tags: ["elixir"]})

    {:ok, video} =
      Items.create_item(%{url: "https://example.com/video1", content_type: "video", tags: ["phoenix"]})

    {:ok, processing} =
      Items.create_item(%{url: "https://example.com/processing1", status: "processing"})

    {:ok, failed} =
      Items.create_item(%{url: "https://example.com/failed1", status: "failed"})

    %{article1: article1, article2: article2, video: video, processing: processing, failed: failed}
  end

  describe "list_items/1 extended filters" do
    test "filters by content_type" do
      items = Items.list_items(content_type: "article")
      assert length(items) == 2
      assert Enum.all?(items, &(&1.content_type == "article"))
    end

    test "filters by tag" do
      items = Items.list_items(tag: "phoenix")
      assert length(items) == 2
      urls = Enum.map(items, & &1.url)
      assert "https://example.com/article1" in urls
      assert "https://example.com/video1" in urls
    end

    test "combines content_type and tag filters" do
      items = Items.list_items(content_type: "article", tag: "phoenix")
      assert length(items) == 1
      assert hd(items).url == "https://example.com/article1"
    end

    test "orders by inserted_at desc" do
      items = Items.list_items([])
      dates = Enum.map(items, & &1.inserted_at)
      assert dates == Enum.sort(dates, {:desc, DateTime})
    end
  end

  describe "count_by_content_type/0" do
    test "returns counts grouped by content_type" do
      counts = Items.count_by_content_type()
      assert counts["article"] == 2
      assert counts["video"] == 1
    end

    test "excludes items with nil content_type" do
      counts = Items.count_by_content_type()
      refute Map.has_key?(counts, nil)
    end
  end

  describe "count_by_tag/0" do
    test "returns counts for each tag" do
      counts = Items.count_by_tag()
      assert counts["elixir"] == 2
      assert counts["phoenix"] == 2
    end
  end

  describe "list_in_progress_items/0" do
    test "returns items with active or failed statuses" do
      items = Items.list_in_progress_items()
      statuses = Enum.map(items, & &1.status)
      assert "processing" in statuses
      assert "failed" in statuses
      # bootstrapping items are included by default (setup items start as bootstrapping)
      assert "bootstrapping" in statuses
    end
  end

  describe "read_artifact_content/2" do
    test "reads file content from artifact path" do
      {:ok, item} = Items.create_item(%{url: "https://example.com/read-test"})

      tmp = Path.join(System.tmp_dir!(), "cham_read_test_#{:erlang.unique_integer([:positive])}")
      stage_dir = Path.join(tmp, "processing/test-stage-20260404T120000Z")
      File.mkdir_p!(stage_dir)
      File.write!(Path.join(stage_dir, "content.txt"), "Hello, world!")
      on_exit(fn -> File.rm_rf!(tmp) end)

      {:ok, item} = Items.update_item(item, %{bootstrap_path: tmp})

      {:ok, artifact} =
        Items.create_artifact(%{
          item_id: item.id,
          stage: "test-stage",
          labels: %{"origin" => "original"},
          filenames: ["content.txt"],
          path: "processing/test-stage-20260404T120000Z",
          status: "produced"
        })

      assert {:ok, "Hello, world!"} = Items.read_artifact_content(item, artifact)
    end

    test "returns error for missing file" do
      {:ok, item} = Items.create_item(%{url: "https://example.com/read-missing"})

      tmp = Path.join(System.tmp_dir!(), "cham_read_missing_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      {:ok, item} = Items.update_item(item, %{bootstrap_path: tmp})

      {:ok, artifact} =
        Items.create_artifact(%{
          item_id: item.id,
          stage: "missing",
          labels: %{},
          filenames: ["nope.txt"],
          path: "processing/missing-20260404T120000Z",
          status: "produced"
        })

      assert {:error, _} = Items.read_artifact_content(item, artifact)
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
mix test test/cham/items_query_test.exs
```

- [ ] **Step 3: Implement the query extensions**

Add to `lib/cham/items.ex` — extend `list_items/1` and add new functions. The existing `list_items/1` filters by `{:status, status}`. Add support for `:content_type`, `:tag`, and default ordering.

Replace the existing `list_items/1` function:

```elixir
  def list_items(filters \\ []) do
    Item
    |> apply_filters(filters)
    |> order_by([i], desc: i.inserted_at)
    |> Repo.all()
  end

  defp apply_filters(query, []), do: query

  defp apply_filters(query, [{:status, status} | rest]) do
    query
    |> where([i], i.status == ^status)
    |> apply_filters(rest)
  end

  defp apply_filters(query, [{:content_type, content_type} | rest]) do
    query
    |> where([i], i.content_type == ^content_type)
    |> apply_filters(rest)
  end

  defp apply_filters(query, [{:tag, tag} | rest]) do
    query
    |> where([i], ^tag in i.tags)
    |> apply_filters(rest)
  end

  defp apply_filters(query, [_ | rest]), do: apply_filters(query, rest)

  def count_by_content_type do
    Item
    |> where([i], not is_nil(i.content_type))
    |> group_by([i], i.content_type)
    |> select([i], {i.content_type, count(i.id)})
    |> Repo.all()
    |> Map.new()
  end

  def count_by_tag do
    Item
    |> select([i], i.tags)
    |> Repo.all()
    |> List.flatten()
    |> Enum.frequencies()
  end

  def list_in_progress_items do
    Item
    |> where([i], i.status in ["bootstrapping", "processing", "failed", "incomplete"])
    |> order_by([i], desc: i.inserted_at)
    |> Repo.all()
  end

  def read_artifact_content(item, artifact) do
    item_dir = item.archive_path || item.bootstrap_path

    case {item_dir, artifact.filenames} do
      {nil, _} ->
        {:error, :no_item_dir}

      {_, []} ->
        {:error, :no_filenames}

      {dir, [filename | _]} ->
        path = Path.join([dir, artifact.path, filename])

        case File.read(path) do
          {:ok, content} -> {:ok, content}
          {:error, reason} -> {:error, reason}
        end
    end
  end
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
mix test test/cham/items_query_test.exs
```

Expected: all tests pass.

- [ ] **Step 5: Run full test suite**

```bash
mix test
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add lib/cham/items.ex test/cham/items_query_test.exs
git commit -m "feat: add Items query extensions for web UI

Filter by content_type and tag, count_by_content_type/tag for sidebar
facets, list_in_progress_items for sidebar, read_artifact_content for
displaying artifact file content. Ordered by inserted_at desc."
```

---

## Task 2: Layout and Routing

Replace the default Phoenix app layout header with Cham branding and add live routes for dashboard and item detail.

**Files:**
- Modify: `lib/cham_web/components/layouts/app.html.heex`
- Modify: `lib/cham_web/router.ex`
- Remove: `lib/cham_web/controllers/page_controller.ex` (replaced by DashboardLive)
- Remove: `lib/cham_web/controllers/page_html.ex`
- Remove: `lib/cham_web/controllers/page_html/home.html.heex`

- [ ] **Step 1: Replace the app layout**

Replace the entire content of `lib/cham_web/components/layouts/app.html.heex`:

```heex
<main>
  <.flash_group flash={@flash} />
  {@inner_content}
</main>
```

The dashboard and item detail LiveViews manage their own full layouts including headers/sidebars, so the app layout just provides flash messages and content.

- [ ] **Step 2: Update the router**

Replace the contents of the `scope "/", ChamWeb do` block in `lib/cham_web/router.ex`:

```elixir
  scope "/", ChamWeb do
    pipe_through :browser

    live "/", DashboardLive
    live "/items/:id", ItemDetailLive
  end
```

- [ ] **Step 3: Remove the old page controller files**

```bash
rm lib/cham_web/controllers/page_controller.ex
rm lib/cham_web/controllers/page_html.ex
rm -rf lib/cham_web/controllers/page_html
```

- [ ] **Step 4: Create placeholder LiveViews so the app compiles**

Create `lib/cham_web/live/dashboard_live.ex`:

```elixir
defmodule ChamWeb.DashboardLive do
  use ChamWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end
end
```

Create `lib/cham_web/live/dashboard_live.html.heex`:

```heex
<div class="min-h-screen bg-gray-50">
  <p>Dashboard placeholder</p>
</div>
```

Create `lib/cham_web/live/item_detail_live.ex`:

```elixir
defmodule ChamWeb.ItemDetailLive do
  use ChamWeb, :live_view

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    {:ok, assign(socket, :item_id, id)}
  end
end
```

Create `lib/cham_web/live/item_detail_live.html.heex`:

```heex
<div class="min-h-screen bg-gray-50">
  <p>Item detail placeholder for {@item_id}</p>
</div>
```

- [ ] **Step 5: Remove old page controller test**

```bash
rm test/cham_web/controllers/page_controller_test.exs
```

- [ ] **Step 6: Verify app compiles and boots**

```bash
mix test
```

Expected: all existing tests pass (the page controller test was removed). The app should compile cleanly.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: replace Phoenix default with Cham layout and live routes

Remove default page controller. Add live routes for DashboardLive (/)
and ItemDetailLive (/items/:id). Simplify app layout to just flash +
content since LiveViews manage their own layouts."
```

---

## Task 3: Shared UI Components

Create reusable function components for badges, timestamps, content availability states, and progress bars.

**Files:**
- Create: `lib/cham_web/components/ui_components.ex`

- [ ] **Step 1: Create the UI components module**

Create `lib/cham_web/components/ui_components.ex`:

```elixir
defmodule ChamWeb.UIComponents do
  use Phoenix.Component

  @doc """
  Renders a colored badge for content types.
  """
  attr :type, :string, required: true

  def content_type_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium",
      content_type_colors(@type)
    ]}>
      {content_type_label(@type)}
    </span>
    """
  end

  defp content_type_colors("article"), do: "bg-blue-100 text-blue-700"
  defp content_type_colors("video"), do: "bg-pink-100 text-pink-700"
  defp content_type_colors("document"), do: "bg-green-100 text-green-700"
  defp content_type_colors("podcast"), do: "bg-purple-100 text-purple-700"
  defp content_type_colors(_), do: "bg-gray-100 text-gray-700"

  defp content_type_label("article"), do: "Article"
  defp content_type_label("video"), do: "Video"
  defp content_type_label("document"), do: "Document"
  defp content_type_label("podcast"), do: "Podcast"
  defp content_type_label(nil), do: "Unknown"
  defp content_type_label(other), do: String.capitalize(other)

  @doc """
  Renders a colored badge for item/stage status.
  """
  attr :status, :string, required: true

  def status_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium",
      status_colors(@status)
    ]}>
      {status_label(@status)}
    </span>
    """
  end

  defp status_colors("bootstrapping"), do: "bg-blue-100 text-blue-700"
  defp status_colors("processing"), do: "bg-amber-100 text-amber-700"
  defp status_colors("complete"), do: "bg-green-100 text-green-700"
  defp status_colors("incomplete"), do: "bg-yellow-100 text-yellow-700"
  defp status_colors("failed"), do: "bg-red-100 text-red-700"
  defp status_colors("started"), do: "bg-blue-100 text-blue-700"
  defp status_colors("completed"), do: "bg-green-100 text-green-700"
  defp status_colors("snoozed"), do: "bg-yellow-100 text-yellow-700"
  defp status_colors(_), do: "bg-gray-100 text-gray-700"

  defp status_label("bootstrapping"), do: "Bootstrapping"
  defp status_label("processing"), do: "Processing"
  defp status_label("complete"), do: "Complete"
  defp status_label("incomplete"), do: "Incomplete"
  defp status_label("failed"), do: "Failed"
  defp status_label("started"), do: "Running"
  defp status_label("completed"), do: "Done"
  defp status_label("snoozed"), do: "Snoozed"
  defp status_label(other), do: String.capitalize(to_string(other))

  @doc """
  Renders a colored badge for pipeline stage names.
  """
  attr :stage, :string, required: true

  def stage_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium",
      stage_colors(@stage)
    ]}>
      {stage_label(@stage)}
    </span>
    """
  end

  defp stage_colors(stage) when stage in ["download", "generic_download_url"], do: "bg-blue-100 text-blue-700"
  defp stage_colors(stage) when stage in ["transcribe", "transcribe_whisper"], do: "bg-purple-100 text-purple-700"
  defp stage_colors(stage) when stage in ["summarize", "summarize_ollama"], do: "bg-amber-100 text-amber-700"
  defp stage_colors(_), do: "bg-gray-100 text-gray-700"

  defp stage_label(stage) do
    stage
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  @doc """
  Renders a relative timestamp (e.g. "2 hours ago").
  """
  attr :at, :any, required: true

  def relative_time(assigns) do
    ~H"""
    <time datetime={DateTime.to_iso8601(@at)} title={Calendar.strftime(@at, "%Y-%m-%d %H:%M")}>
      {format_relative(@at)}
    </time>
    """
  end

  defp format_relative(datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86400 -> "#{div(diff, 3600)}h ago"
      diff < 2_592_000 -> "#{div(diff, 86400)}d ago"
      true -> Calendar.strftime(datetime, "%b %d, %Y")
    end
  end

  @doc """
  Renders a tag pill.
  """
  attr :tag, :string, required: true
  attr :count, :integer, default: nil
  attr :active, :boolean, default: false
  attr :rest, :global

  def tag_pill(assigns) do
    ~H"""
    <span
      class={[
        "inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium cursor-pointer",
        if(@active, do: "bg-indigo-100 text-indigo-700 ring-1 ring-indigo-300", else: "bg-gray-100 text-gray-600 hover:bg-gray-200")
      ]}
      {@rest}
    >
      {@tag}
      <span :if={@count} class="ml-1 text-gray-400">{@count}</span>
    </span>
    """
  end

  @doc """
  Renders a progress bar.
  """
  attr :progress, :float, required: true
  attr :message, :string, default: nil

  def progress_bar(assigns) do
    ~H"""
    <div>
      <div class="flex justify-between text-xs text-gray-500 mb-1">
        <span :if={@message}>{@message}</span>
        <span>{trunc(@progress * 100)}%</span>
      </div>
      <div class="w-full bg-gray-200 rounded-full h-1.5">
        <div class="bg-indigo-600 h-1.5 rounded-full transition-all" style={"width: #{trunc(@progress * 100)}%"}>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders the appropriate content availability state.
  state is one of: :available, :processing, :failed, :not_requested
  """
  attr :state, :atom, required: true
  attr :error, :string, default: nil
  slot :inner_block

  def content_state(assigns) do
    ~H"""
    <div :if={@state == :available}>
      {render_slot(@inner_block)}
    </div>
    <div :if={@state == :processing} class="flex items-center gap-2 text-gray-500 py-8">
      <svg class="animate-spin h-5 w-5" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24">
        <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4" />
        <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z" />
      </svg>
      <span>Currently being generated...</span>
    </div>
    <div :if={@state == :failed} class="text-red-600 py-8">
      <p class="font-medium">Generation failed</p>
      <p :if={@error} class="text-sm mt-1">{@error}</p>
    </div>
    <div :if={@state == :not_requested} class="text-gray-400 py-8">
      Not available for this item
    </div>
    """
  end

  @doc """
  Extracts the domain from a URL string.
  """
  def domain_from_url(url) when is_binary(url) do
    case URI.parse(url) do
      %{host: host} when is_binary(host) -> host
      _ -> url
    end
  end

  def domain_from_url(_), do: ""
end
```

- [ ] **Step 2: Import UI components in ChamWeb**

Add to `lib/cham_web.ex` in the `html_helpers` function, alongside the existing `import ChamWeb.CoreComponents` line:

```elixir
import ChamWeb.UIComponents
```

- [ ] **Step 3: Format and verify**

```bash
mix format
mix test
```

Expected: all tests pass, no compilation errors.

- [ ] **Step 4: Commit**

```bash
git add lib/cham_web/components/ui_components.ex lib/cham_web.ex
git commit -m "feat: add shared UI components for badges, tags, progress bars

Content type badges, status badges, stage badges, tag pills, relative
timestamps, progress bars, and content availability state display.
Imported globally via ChamWeb html_helpers."
```

---

## Task 4: Dashboard LiveView

Build the dashboard with sidebar (in-progress, content type facets, tags) and main content area (hero text, item list with content-type-specific display). Filter state via URL query params.

**Files:**
- Modify: `lib/cham_web/live/dashboard_live.ex`
- Modify: `lib/cham_web/live/dashboard_live.html.heex`
- Create: `test/cham_web/live/dashboard_live_test.exs`

- [ ] **Step 1: Write failing tests**

Create `test/cham_web/live/dashboard_live_test.exs`:

```elixir
defmodule ChamWeb.DashboardLiveTest do
  use ChamWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Cham.Items

  setup do
    {:ok, article} =
      Items.create_item(%{
        url: "https://example.com/article",
        title: "Test Article",
        content_type: "article",
        tags: ["elixir"],
        status: "complete"
      })

    {:ok, video} =
      Items.create_item(%{
        url: "https://example.com/video",
        title: "Test Video",
        content_type: "video",
        tags: ["phoenix"],
        status: "complete"
      })

    {:ok, processing} =
      Items.create_item(%{
        url: "https://example.com/processing",
        status: "processing"
      })

    %{article: article, video: video, processing: processing}
  end

  describe "mount" do
    test "renders dashboard with hero text", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "Cham knows about"
      assert html =~ "pieces of information"
    end

    test "shows items in the list", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "Test Article"
      assert html =~ "Test Video"
    end

    test "shows content type facets in sidebar", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "Article"
      assert html =~ "Video"
    end

    test "shows in-progress count", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "In Progress"
    end
  end

  describe "filtering" do
    test "filters by content type via URL param", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/?type=article")
      assert html =~ "Test Article"
      refute html =~ "Test Video"
    end

    test "filters by tag via URL param", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/?tag=elixir")
      assert html =~ "Test Article"
      refute html =~ "Test Video"
    end

    test "clicking content type applies filter", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      html = view |> element("[data-filter-type=\"article\"]") |> render_click()
      assert_patched(view, "/?type=article")
      assert html =~ "Test Article"
    end

    test "clicking active content type removes filter", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/?type=article")
      view |> element("[data-filter-type=\"article\"]") |> render_click()
      assert_patched(view, "/")
    end
  end

  describe "empty states" do
    test "shows empty archive message when no items", %{conn: conn} do
      Cham.Repo.delete_all(Cham.Items.Artifact)
      Cham.Repo.delete_all(Cham.Items.Item)
      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "Submit your first URL"
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
mix test test/cham_web/live/dashboard_live_test.exs
```

- [ ] **Step 3: Implement DashboardLive**

Replace `lib/cham_web/live/dashboard_live.ex`:

```elixir
defmodule ChamWeb.DashboardLive do
  use ChamWeb, :live_view

  alias Cham.Items

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Archive")
     |> assign(:show_in_progress, false)
     |> assign(:show_submit_modal, false)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    active_type = params["type"]
    active_tag = params["tag"]

    filters =
      []
      |> then(fn f -> if active_type, do: [{:content_type, active_type} | f], else: f end)
      |> then(fn f -> if active_tag, do: [{:tag, active_tag} | f], else: f end)

    items = Items.list_items(filters)
    in_progress = Items.list_in_progress_items()
    type_counts = Items.count_by_content_type()
    tag_counts = Items.count_by_tag()

    active_count =
      Enum.count(in_progress, &(&1.status in ["bootstrapping", "processing"]))

    {:noreply,
     socket
     |> assign(:items, items)
     |> assign(:in_progress, in_progress)
     |> assign(:active_type, active_type)
     |> assign(:active_tag, active_tag)
     |> assign(:type_counts, type_counts)
     |> assign(:tag_counts, tag_counts)
     |> assign(:active_count, active_count)
     |> assign(:total_count, length(items))}
  end

  @impl true
  def handle_event("toggle_in_progress", _params, socket) do
    {:noreply, assign(socket, :show_in_progress, !socket.assigns.show_in_progress)}
  end

  def handle_event("filter_type", %{"type" => type}, socket) do
    params =
      if socket.assigns.active_type == type do
        remove_param(socket, :type)
      else
        put_param(socket, :type, type)
      end

    {:noreply, push_patch(socket, to: ~p"/?#{params}")}
  end

  def handle_event("filter_tag", %{"tag" => tag}, socket) do
    params =
      if socket.assigns.active_tag == tag do
        remove_param(socket, :tag)
      else
        put_param(socket, :tag, tag)
      end

    {:noreply, push_patch(socket, to: ~p"/?#{params}")}
  end

  defp current_params(socket) do
    params = %{}
    params = if socket.assigns.active_type, do: Map.put(params, :type, socket.assigns.active_type), else: params
    if socket.assigns.active_tag, do: Map.put(params, :tag, socket.assigns.active_tag), else: params
  end

  defp put_param(socket, key, value) do
    current_params(socket) |> Map.put(key, value)
  end

  defp remove_param(socket, key) do
    current_params(socket) |> Map.delete(key)
  end

  defp hero_text(0, nil, nil), do: "Cham knows about 0 pieces of information"
  defp hero_text(count, nil, nil), do: "Cham knows about #{count} pieces of information"
  defp hero_text(count, type, nil) when is_binary(type), do: "#{count} #{Inflex.pluralize(type)}"
  defp hero_text(count, nil, tag) when is_binary(tag), do: "#{count} items tagged #{tag}"
  defp hero_text(count, type, tag), do: "#{count} #{Inflex.pluralize(type)} tagged #{tag}"
end
```

**Note:** We don't need the `Inflex` library. Replace the `hero_text` helper with a simpler version that doesn't pluralize:

```elixir
  defp hero_text(assigns) do
    count = assigns.total_count
    type = assigns.active_type
    tag = assigns.active_tag

    cond do
      type && tag -> "#{count} #{type}s tagged #{tag}"
      type -> "#{count} #{type}s"
      tag -> "#{count} items tagged #{tag}"
      true -> "Cham knows about #{count} pieces of information"
    end
  end
```

- [ ] **Step 4: Implement dashboard template**

Replace `lib/cham_web/live/dashboard_live.html.heex`:

```heex
<div class="flex min-h-screen">
  <%!-- Sidebar --%>
  <aside class="w-64 bg-white border-r border-gray-200 flex-shrink-0 p-4 space-y-6">
    <%!-- Logo --%>
    <div class="text-xl font-bold text-gray-900">Cham</div>

    <%!-- Add URL button --%>
    <button
      phx-click={show_modal("submit-modal")}
      class="w-full rounded-lg bg-indigo-600 px-3 py-2 text-sm font-semibold text-white hover:bg-indigo-500"
    >
      + Add URL
    </button>

    <%!-- In Progress --%>
    <div>
      <button
        phx-click="toggle_in_progress"
        class="flex items-center justify-between w-full text-sm font-medium text-gray-700"
      >
        <span>In Progress</span>
        <span :if={@active_count > 0} class="inline-flex items-center rounded-full bg-indigo-100 text-indigo-700 px-2 py-0.5 text-xs font-medium">
          {@active_count}
        </span>
        <.icon :if={@active_count == 0 && length(@in_progress) > 0} name="hero-exclamation-triangle-mini" class="h-4 w-4 text-yellow-500" />
      </button>
      <div :if={@show_in_progress} class="mt-2 space-y-1">
        <.link
          :for={item <- @in_progress}
          navigate={~p"/items/#{item.id}"}
          class="block rounded-md px-2 py-1.5 text-sm text-gray-600 hover:bg-gray-50"
        >
          <div class="flex items-center gap-2">
            <.status_badge status={item.status} />
            <span class="truncate">{item.title || truncate_url(item.url)}</span>
          </div>
        </.link>
      </div>
    </div>

    <%!-- Content Type Facets --%>
    <div>
      <div class="text-xs font-semibold text-gray-400 uppercase tracking-wider mb-2">Content Types</div>
      <div class="space-y-1">
        <button
          :for={{type, count} <- Enum.sort(@type_counts)}
          phx-click="filter_type"
          phx-value-type={type}
          data-filter-type={type}
          class={[
            "flex items-center justify-between w-full rounded-md px-2 py-1.5 text-sm",
            if(@active_type == type, do: "bg-indigo-50 text-indigo-700 font-medium", else: "text-gray-600 hover:bg-gray-50")
          ]}
        >
          <span>{content_type_label(type)}</span>
          <span class="text-xs text-gray-400">{count}</span>
        </button>
      </div>
    </div>

    <%!-- Tags --%>
    <div :if={map_size(@tag_counts) > 0}>
      <div class="text-xs font-semibold text-gray-400 uppercase tracking-wider mb-2">Tags</div>
      <div class="flex flex-wrap gap-1.5">
        <.tag_pill
          :for={{tag, count} <- Enum.sort(@tag_counts)}
          tag={tag}
          count={count}
          active={@active_tag == tag}
          phx-click="filter_tag"
          phx-value-tag={tag}
        />
      </div>
    </div>
  </aside>

  <%!-- Main Content --%>
  <div class="flex-1 bg-gray-50 p-8">
    <%!-- Hero --%>
    <h1 class="text-2xl font-bold text-gray-900 mb-6">{hero_text(assigns)}</h1>

    <%!-- Search placeholder --%>
    <div class="mb-8">
      <input
        type="text"
        placeholder={if @active_type, do: "Search #{@active_type}s...", else: "Search your archive..."}
        disabled
        class="w-full rounded-lg border border-gray-300 bg-white px-4 py-2.5 text-gray-400 cursor-not-allowed"
      />
    </div>

    <%!-- Item List --%>
    <div :if={@items == [] && is_nil(@active_type) && is_nil(@active_tag)} class="text-center py-16 text-gray-400">
      <p class="text-lg">Submit your first URL to get started</p>
    </div>

    <div :if={@items == [] && (@active_type || @active_tag)} class="text-center py-16 text-gray-400">
      <p class="text-lg">No items match this filter</p>
    </div>

    <%!-- Card grid for videos and documents --%>
    <div :if={@items != [] && @active_type in ["video", "document"]} class="grid grid-cols-3 gap-4">
      <.link
        :for={item <- @items}
        navigate={~p"/items/#{item.id}?#{return_params(assigns)}"}
        class="block rounded-lg border border-gray-200 bg-white p-4 hover:border-indigo-300 hover:shadow-sm transition"
      >
        <div class="aspect-video bg-gray-100 rounded mb-3 flex items-center justify-center">
          <.icon :if={@active_type == "video"} name="hero-play-circle" class="h-8 w-8 text-gray-300" />
          <.icon :if={@active_type == "document"} name="hero-document-text" class="h-8 w-8 text-gray-300" />
        </div>
        <p class="font-medium text-gray-900 text-sm truncate">{item.title || truncate_url(item.url)}</p>
        <p class="text-xs text-gray-400 mt-1">
          {domain_from_url(item.url)} · <.relative_time at={item.inserted_at} />
        </p>
      </.link>
    </div>

    <%!-- List rows for mixed, articles, podcasts --%>
    <div :if={@items != [] && @active_type not in ["video", "document"]} class="space-y-1">
      <.link
        :for={item <- @items}
        navigate={~p"/items/#{item.id}?#{return_params(assigns)}"}
        class="flex items-center gap-3 rounded-lg border border-gray-200 bg-white px-4 py-3 hover:border-indigo-300 hover:shadow-sm transition"
      >
        <.content_type_badge type={item.content_type} />
        <span class="font-medium text-gray-900 text-sm flex-1 truncate">{item.title || truncate_url(item.url)}</span>
        <span class="text-xs text-gray-400">{domain_from_url(item.url)}</span>
        <span class="text-xs text-gray-400"><.relative_time at={item.inserted_at} /></span>
      </.link>
    </div>
  </div>
</div>

<%!-- Submit Modal (rendered but hidden until triggered) --%>
<.modal id="submit-modal">
  <div class="text-lg font-semibold mb-4">Add URL</div>
  <p class="text-sm text-gray-500 mb-4">Submit a URL to archive</p>
</.modal>
```

Add helper functions to `lib/cham_web/live/dashboard_live.ex`:

```elixir
  defp content_type_label("article"), do: "Articles"
  defp content_type_label("video"), do: "Videos"
  defp content_type_label("document"), do: "Documents"
  defp content_type_label("podcast"), do: "Podcasts"
  defp content_type_label(other), do: String.capitalize(to_string(other)) <> "s"

  defp truncate_url(url) when is_binary(url) do
    uri = URI.parse(url)
    host = uri.host || ""
    path = uri.path || ""

    display = host <> path
    if String.length(display) > 50, do: String.slice(display, 0, 47) <> "...", else: display
  end

  defp truncate_url(_), do: ""

  defp return_params(assigns) do
    params = %{}
    params = if assigns.active_type, do: Map.put(params, "return_type", assigns.active_type), else: params
    if assigns.active_tag, do: Map.put(params, "return_tag", assigns.active_tag), else: params
  end
```

- [ ] **Step 5: Run tests**

```bash
mix format
mix test test/cham_web/live/dashboard_live_test.exs
```

Expected: all tests pass.

- [ ] **Step 6: Run full test suite**

```bash
mix test
```

Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: add Dashboard LiveView with sidebar and item list

Two-panel layout: sidebar with in-progress items, content type facets,
and tag pills. Main area with hero text and content-type-specific item
display (list rows or card grid). Filters via URL query params."
```

---

## Task 5: Submit Modal

Wire up the submit modal in the dashboard to call `Pipeline.submit_url/2` and handle success/error.

**Files:**
- Modify: `lib/cham_web/live/dashboard_live.ex`
- Modify: `lib/cham_web/live/dashboard_live.html.heex`
- Modify: `test/cham_web/live/dashboard_live_test.exs`

- [ ] **Step 1: Add submit tests**

Add to `test/cham_web/live/dashboard_live_test.exs`:

```elixir
  describe "submit modal" do
    test "submitting a URL creates an item", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      view
      |> form("#submit-form", %{url: "https://example.com/new-item"})
      |> render_submit()

      flash = assert_redirected(view, "/")
      assert flash["info"] =~ "submitted"
    end

    test "submitting a duplicate URL shows error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      html =
        view
        |> form("#submit-form", %{url: "https://example.com/article"})
        |> render_submit()

      assert html =~ "already"
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
mix test test/cham_web/live/dashboard_live_test.exs
```

- [ ] **Step 3: Update the modal in the template**

Replace the submit modal section at the bottom of `lib/cham_web/live/dashboard_live.html.heex`:

```heex
<.modal id="submit-modal">
  <div class="text-lg font-semibold mb-4">Add URL</div>
  <form id="submit-form" phx-submit="submit_url" class="space-y-4">
    <div>
      <input
        type="url"
        name="url"
        placeholder="https://..."
        required
        class="w-full rounded-lg border border-gray-300 px-4 py-2.5 focus:border-indigo-500 focus:ring-indigo-500"
        phx-mounted={JS.focus()}
      />
      <p :if={@submit_error} class="mt-1 text-sm text-red-600">{@submit_error}</p>
    </div>
    <div class="flex justify-end">
      <button type="submit" class="rounded-lg bg-indigo-600 px-4 py-2 text-sm font-semibold text-white hover:bg-indigo-500">
        Submit
      </button>
    </div>
  </form>
</.modal>
```

- [ ] **Step 4: Add submit handling to the LiveView**

Add to `lib/cham_web/live/dashboard_live.ex`:

In `mount`, add `assign(:submit_error, nil)` to the assign chain.

Add event handler:

```elixir
  def handle_event("submit_url", %{"url" => url}, socket) do
    case Cham.Pipeline.submit_url(url) do
      {:ok, _item} ->
        {:noreply,
         socket
         |> put_flash(:info, "URL submitted for processing")
         |> push_navigate(to: ~p"/")}

      {:error, changeset} ->
        error_msg =
          changeset
          |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
          |> Enum.map_join(", ", fn {_field, msgs} -> Enum.join(msgs, ", ") end)

        {:noreply,
         socket
         |> assign(:submit_error, error_msg)}
    end
  end
```

- [ ] **Step 5: Run tests**

```bash
mix format
mix test test/cham_web/live/dashboard_live_test.exs
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: wire up submit modal for URL submission

Calls Pipeline.submit_url, shows inline errors for duplicates/invalid
URLs, flashes success and redirects on success."
```

---

## Task 6: Dashboard Real-Time Updates

Subscribe to EventBus for real-time updates to the in-progress sidebar section.

**Files:**
- Modify: `lib/cham_web/live/dashboard_live.ex`
- Modify: `test/cham_web/live/dashboard_live_test.exs`

- [ ] **Step 1: Add real-time tests**

Add to `test/cham_web/live/dashboard_live_test.exs`:

```elixir
  describe "real-time updates" do
    test "new item appears in in-progress when created", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      # Toggle in-progress open
      view |> element("button", "In Progress") |> render_click()

      # Simulate an item status change event
      {:ok, new_item} = Items.create_item(%{url: "https://example.com/realtime-test"})
      Cham.EventBus.publish("item:created", %{item: new_item})

      # Give handle_info time to process
      html = render(view)
      assert html =~ "example.com/realtime-test"
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
mix test test/cham_web/live/dashboard_live_test.exs --only real_time
```

- [ ] **Step 3: Add EventBus subscription to DashboardLive**

In `mount/3` of `lib/cham_web/live/dashboard_live.ex`, add after the assigns:

```elixir
    if connected?(socket) do
      Cham.EventBus.subscribe("item")
    end
```

Add `handle_info` clauses:

```elixir
  @impl true
  def handle_info(_event, socket) do
    # Reload in-progress items on any item event
    in_progress = Items.list_in_progress_items()

    active_count =
      Enum.count(in_progress, &(&1.status in ["bootstrapping", "processing"]))

    # Reload type/tag counts and items list
    type_counts = Items.count_by_content_type()
    tag_counts = Items.count_by_tag()

    filters =
      []
      |> then(fn f -> if socket.assigns.active_type, do: [{:content_type, socket.assigns.active_type} | f], else: f end)
      |> then(fn f -> if socket.assigns.active_tag, do: [{:tag, socket.assigns.active_tag} | f], else: f end)

    items = Items.list_items(filters)

    {:noreply,
     socket
     |> assign(:in_progress, in_progress)
     |> assign(:active_count, active_count)
     |> assign(:type_counts, type_counts)
     |> assign(:tag_counts, tag_counts)
     |> assign(:items, items)
     |> assign(:total_count, length(items))}
  end
```

- [ ] **Step 4: Run tests**

```bash
mix format
mix test test/cham_web/live/dashboard_live_test.exs
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: add real-time dashboard updates via EventBus

Subscribe to item topic on mount. Reload in-progress items, counts,
and item list on any item event."
```

---

## Task 7: Item Detail — Basic Content and Bottom Pane

Build the item detail page with primary content display, collapsible bottom pane with tabs, and content availability states.

**Files:**
- Modify: `lib/cham_web/live/item_detail_live.ex`
- Modify: `lib/cham_web/live/item_detail_live.html.heex`
- Create: `test/cham_web/live/item_detail_live_test.exs`

- [ ] **Step 1: Write failing tests**

Create `test/cham_web/live/item_detail_live_test.exs`:

```elixir
defmodule ChamWeb.ItemDetailLiveTest do
  use ChamWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Cham.Items

  setup do
    {:ok, item} =
      Items.create_item(%{
        url: "https://example.com/detail-test",
        title: "Test Article Detail",
        content_type: "article",
        tags: ["elixir", "testing"],
        status: "complete"
      })

    %{item: item}
  end

  describe "mount" do
    test "renders item detail with title", %{conn: conn, item: item} do
      {:ok, _view, html} = live(conn, ~p"/items/#{item.id}")
      assert html =~ "Test Article Detail"
    end

    test "shows back link", %{conn: conn, item: item} do
      {:ok, _view, html} = live(conn, ~p"/items/#{item.id}")
      assert html =~ "Back"
    end

    test "shows tag pills", %{conn: conn, item: item} do
      {:ok, _view, html} = live(conn, ~p"/items/#{item.id}")
      assert html =~ "elixir"
      assert html =~ "testing"
    end

    test "shows external link to source", %{conn: conn, item: item} do
      {:ok, _view, html} = live(conn, ~p"/items/#{item.id}")
      assert html =~ "example.com"
    end
  end

  describe "bottom pane tabs" do
    test "shows tab bar", %{conn: conn, item: item} do
      {:ok, _view, html} = live(conn, ~p"/items/#{item.id}")
      assert html =~ "Summary"
      assert html =~ "Metadata"
      assert html =~ "Chat"
    end

    test "clicking a tab shows its content", %{conn: conn, item: item} do
      {:ok, view, _html} = live(conn, ~p"/items/#{item.id}")
      html = view |> element("[data-tab=\"metadata\"]") |> render_click()
      assert html =~ item.url
    end
  end

  describe "content availability" do
    test "shows not-requested state when no artifacts", %{conn: conn, item: item} do
      {:ok, view, _html} = live(conn, ~p"/items/#{item.id}")
      html = view |> element("[data-tab=\"summary\"]") |> render_click()
      assert html =~ "Not available"
    end
  end

  describe "processing view" do
    test "shows status badge for processing items", %{conn: conn} do
      {:ok, processing} =
        Items.create_item(%{url: "https://example.com/processing-detail", status: "processing"})

      {:ok, _view, html} = live(conn, ~p"/items/#{processing.id}")
      assert html =~ "Processing"
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
mix test test/cham_web/live/item_detail_live_test.exs
```

- [ ] **Step 3: Implement ItemDetailLive**

Replace `lib/cham_web/live/item_detail_live.ex`:

```elixir
defmodule ChamWeb.ItemDetailLive do
  use ChamWeb, :live_view

  alias Cham.Items
  alias Cham.JobTracking.Tracker

  @impl true
  def mount(%{"id" => id} = params, _session, socket) do
    item = Items.get_item!(id)
    artifacts = Items.list_artifacts(item.id)
    stage_history = Tracker.get_stage_history(item.id)

    return_path = build_return_path(params)

    {:ok,
     socket
     |> assign(:page_title, item.title || "Item Detail")
     |> assign(:item, item)
     |> assign(:artifacts, artifacts)
     |> assign(:stage_history, stage_history)
     |> assign(:return_path, return_path)
     |> assign(:active_tab, nil)
     |> assign_content(item, artifacts, stage_history)}
  end

  defp build_return_path(params) do
    query =
      %{}
      |> then(fn q -> if params["return_type"], do: Map.put(q, "type", params["return_type"]), else: q end)
      |> then(fn q -> if params["return_tag"], do: Map.put(q, "tag", params["return_tag"]), else: q end)

    if query == %{}, do: ~p"/", else: ~p"/?#{query}"
  end

  @impl true
  def handle_event("select_tab", %{"tab" => tab}, socket) do
    new_tab = if socket.assigns.active_tab == tab, do: nil, else: tab
    {:noreply, assign(socket, :active_tab, new_tab)}
  end

  defp assign_content(socket, item, artifacts, stage_history) do
    socket
    |> assign(:primary_content, resolve_primary_content(item, artifacts, stage_history))
    |> assign(:summary, resolve_artifact_content(item, artifacts, stage_history, "summary"))
    |> assign(:transcript, resolve_artifact_content(item, artifacts, stage_history, "transcript"))
    |> assign(:metadata_json, Jason.encode!(item.metadata || %{}, pretty: true))
  end

  defp resolve_primary_content(item, artifacts, stage_history) do
    case item.content_type do
      "article" ->
        resolve_artifact_content(item, artifacts, stage_history, "text", "original")

      "video" ->
        resolve_artifact_content(item, artifacts, stage_history, "transcript")

      _ ->
        %{state: :not_requested, content: nil, error: nil}
    end
  end

  defp resolve_artifact_content(item, artifacts, stage_history, type, origin \\ "derived") do
    artifact =
      Enum.find(artifacts, fn a ->
        a.labels["type"] == type && a.labels["origin"] == origin && a.status == "produced"
      end)

    cond do
      artifact ->
        case Items.read_artifact_content(item, artifact) do
          {:ok, content} -> %{state: :available, content: content, error: nil}
          {:error, _} -> %{state: :available, content: "[Could not read file]", error: nil}
        end

      has_running_stage?(stage_history, type) ->
        %{state: :processing, content: nil, error: nil}

      failed_stage = find_failed_stage(stage_history, type) ->
        %{state: :failed, content: nil, error: failed_stage.error}

      true ->
        %{state: :not_requested, content: nil, error: nil}
    end
  end

  defp has_running_stage?(stage_history, type) do
    Enum.any?(stage_history, fn s ->
      s.status == "started" && String.contains?(s.stage, type)
    end)
  end

  defp find_failed_stage(stage_history, type) do
    Enum.find(stage_history, fn s ->
      s.status == "failed" && String.contains?(s.stage, type)
    end)
  end

  defp is_processing?(item) do
    item.status in ["bootstrapping", "processing"]
  end

  defp tabs_for(item) do
    base = ["summary", "metadata", "chat", "actions"]

    case item.content_type do
      type when type in ["video", "podcast"] -> ["summary", "transcript", "metadata", "chat", "actions"]
      _ -> base
    end
  end

  defp tab_label("summary"), do: "Summary"
  defp tab_label("transcript"), do: "Transcript"
  defp tab_label("metadata"), do: "Metadata"
  defp tab_label("chat"), do: "Chat"
  defp tab_label("actions"), do: "Actions"
  defp tab_label(other), do: String.capitalize(other)
end
```

- [ ] **Step 4: Implement item detail template**

Replace `lib/cham_web/live/item_detail_live.html.heex`:

```heex
<div class="min-h-screen bg-gray-50">
  <%!-- Top Bar --%>
  <div class="bg-white border-b border-gray-200 px-8 py-4">
    <div class="flex items-center justify-between">
      <.link navigate={@return_path} class="text-sm text-gray-500 hover:text-gray-700 flex items-center gap-1">
        <.icon name="hero-arrow-left-mini" class="h-4 w-4" />
        Back to archive
      </.link>
      <div class="flex items-center gap-2">
        <.status_badge :if={is_processing?(@item)} status={@item.status} />
        <span
          :for={tag <- @item.tags || []}
          class="inline-flex items-center rounded-full bg-gray-100 px-2.5 py-0.5 text-xs font-medium text-gray-600"
        >
          {tag}
        </span>
      </div>
    </div>
  </div>

  <%!-- Primary Content --%>
  <div class="max-w-4xl mx-auto px-8 py-8">
    <%!-- Header --%>
    <div class="mb-8">
      <h1 class="text-3xl font-bold text-gray-900 mb-2">{@item.title || "Untitled"}</h1>
      <div class="flex items-center gap-3 text-sm text-gray-500">
        <.content_type_badge :if={@item.content_type} type={@item.content_type} />
        <a href={@item.url} target="_blank" rel="noopener" class="hover:text-indigo-600">
          {domain_from_url(@item.url)} ↗
        </a>
        <.relative_time at={@item.inserted_at} />
      </div>
    </div>

    <%!-- Processing View --%>
    <div :if={is_processing?(@item)} class="mb-8 rounded-lg border border-gray-200 bg-white p-6">
      <h2 class="text-sm font-semibold text-gray-700 mb-4">Processing Pipeline</h2>
      <div :if={@stage_history == []} class="text-sm text-gray-400">
        Waiting for pipeline to start...
      </div>
      <div :if={@stage_history != []} class="space-y-3">
        <div :for={stage <- @stage_history} class="flex items-center gap-3 text-sm">
          <.status_badge status={stage.status} />
          <span class="font-medium text-gray-700">{stage.stage}</span>
          <span :if={stage.duration_ms} class="text-gray-400">{stage.duration_ms}ms</span>
          <span :if={stage.error} class="text-red-500 text-xs">{stage.error}</span>
        </div>
      </div>
    </div>

    <%!-- Primary Content Area --%>
    <div :if={@item.content_type == "article"} class="mb-8">
      <.content_state state={@primary_content.state} error={@primary_content.error}>
        <div class="prose prose-gray max-w-none bg-white rounded-lg border border-gray-200 p-8">
          <pre class="whitespace-pre-wrap font-sans text-base">{@primary_content.content}</pre>
        </div>
      </.content_state>
    </div>

    <div :if={@item.content_type == "video"} class="mb-8">
      <div class="aspect-video bg-gray-100 rounded-lg flex items-center justify-center mb-4">
        <div class="text-center text-gray-400">
          <.icon name="hero-play-circle" class="h-12 w-12 mx-auto mb-2" />
          <p>Video playback coming soon</p>
          <a href={@item.url} target="_blank" rel="noopener" class="text-sm text-indigo-600 hover:text-indigo-500">
            Watch on original site ↗
          </a>
        </div>
      </div>
    </div>

    <div :if={@item.content_type == "document"} class="mb-8">
      <div class="aspect-[3/4] max-h-96 bg-gray-100 rounded-lg flex items-center justify-center mb-4">
        <div class="text-center text-gray-400">
          <.icon name="hero-document-text" class="h-12 w-12 mx-auto mb-2" />
          <p>PDF viewer coming soon</p>
          <a href={@item.url} target="_blank" rel="noopener" class="text-sm text-indigo-600 hover:text-indigo-500">
            View original ↗
          </a>
        </div>
      </div>
    </div>

    <div :if={@item.content_type not in ["article", "video", "document"]} class="mb-8">
      <div class="bg-white rounded-lg border border-gray-200 p-6">
        <p class="text-sm text-gray-500 mb-4">Available artifacts:</p>
        <div :if={@artifacts == []} class="text-sm text-gray-400">No artifacts yet</div>
        <div :for={artifact <- @artifacts} class="text-sm text-gray-600 mb-1">
          <span class="font-mono text-xs bg-gray-100 px-1 rounded">{artifact.stage}</span>
          <span :for={{k, v} <- artifact.labels} class="ml-2 text-gray-400">{k}:{v}</span>
        </div>
      </div>
    </div>

    <%!-- Bottom Pane --%>
    <div class="rounded-lg border border-gray-200 bg-white">
      <%!-- Tab Bar --%>
      <div class="flex border-b border-gray-200">
        <button
          :for={tab <- tabs_for(@item)}
          phx-click="select_tab"
          phx-value-tab={tab}
          data-tab={tab}
          class={[
            "px-4 py-3 text-sm font-medium border-b-2 -mb-px",
            if(@active_tab == tab,
              do: "border-indigo-500 text-indigo-600",
              else: "border-transparent text-gray-500 hover:text-gray-700 hover:border-gray-300")
          ]}
        >
          {tab_label(tab)}
        </button>
      </div>

      <%!-- Tab Content --%>
      <div :if={@active_tab} class="p-6">
        <%!-- Summary --%>
        <div :if={@active_tab == "summary"}>
          <.content_state state={@summary.state} error={@summary.error}>
            <div class="prose prose-gray max-w-none">
              <pre class="whitespace-pre-wrap font-sans text-base">{@summary.content}</pre>
            </div>
          </.content_state>
        </div>

        <%!-- Transcript --%>
        <div :if={@active_tab == "transcript"}>
          <.content_state state={@transcript.state} error={@transcript.error}>
            <div class="prose prose-gray max-w-none max-h-96 overflow-y-auto">
              <pre class="whitespace-pre-wrap font-sans text-sm">{@transcript.content}</pre>
            </div>
          </.content_state>
        </div>

        <%!-- Metadata --%>
        <div :if={@active_tab == "metadata"}>
          <pre class="text-sm font-mono bg-gray-50 rounded p-4 overflow-x-auto">{@metadata_json}</pre>
        </div>

        <%!-- Chat placeholder --%>
        <div :if={@active_tab == "chat"} class="text-center py-8 text-gray-400">
          <.icon name="hero-chat-bubble-left-right" class="h-8 w-8 mx-auto mb-2" />
          <p>Chat coming soon</p>
        </div>

        <%!-- Actions placeholder --%>
        <div :if={@active_tab == "actions"} class="text-center py-8 text-gray-400">
          <.icon name="hero-cog-6-tooth" class="h-8 w-8 mx-auto mb-2" />
          <p>Actions coming soon</p>
        </div>
      </div>
    </div>
  </div>
</div>
```

- [ ] **Step 5: Run tests**

```bash
mix format
mix test test/cham_web/live/item_detail_live_test.exs
```

Expected: all tests pass.

- [ ] **Step 6: Run full test suite**

```bash
mix test
```

Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: add Item Detail LiveView with content display and bottom pane

Content-type-adaptive layout with primary content area and collapsible
bottom pane tabs (summary, transcript, metadata, chat, actions). Four
content availability states: available, processing, failed, not requested.
Processing view with stage timeline."
```

---

## Task 8: Item Detail — Real-Time Updates

Subscribe to pipeline events for real-time stage progress and artifact updates on the item detail page.

**Files:**
- Modify: `lib/cham_web/live/item_detail_live.ex`
- Modify: `test/cham_web/live/item_detail_live_test.exs`

- [ ] **Step 1: Add real-time tests**

Add to `test/cham_web/live/item_detail_live_test.exs`:

```elixir
  describe "real-time updates" do
    test "stage progress updates appear", %{conn: conn} do
      {:ok, processing} =
        Items.create_item(%{url: "https://example.com/realtime-detail", status: "processing"})

      {:ok, view, _html} = live(conn, ~p"/items/#{processing.id}")

      # Simulate a stage started event
      alias Cham.Pipeline.Events.StageStarted

      Cham.EventBus.publish("pipeline:stage_started", %StageStarted{
        stage_id: "summarize",
        item_id: processing.id,
        attempt: 1
      })

      # Give handle_info time to process
      Process.sleep(100)
      html = render(view)
      assert html =~ "summarize"
    end

    test "stage completion updates content", %{conn: conn} do
      {:ok, processing} =
        Items.create_item(%{url: "https://example.com/realtime-complete", status: "processing"})

      {:ok, view, _html} = live(conn, ~p"/items/#{processing.id}")

      alias Cham.Pipeline.Events.StageCompleted

      Cham.EventBus.publish("pipeline:stage_completed", %StageCompleted{
        stage_id: "summarize",
        item_id: processing.id,
        duration_ms: 500
      })

      Process.sleep(100)
      html = render(view)
      # The view should have reloaded artifacts and stage history
      assert html =~ "items/#{processing.id}"
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
mix test test/cham_web/live/item_detail_live_test.exs
```

- [ ] **Step 3: Add EventBus subscription and handle_info**

In `mount/3` of `lib/cham_web/live/item_detail_live.ex`, add before the `{:ok, socket}`:

```elixir
    if connected?(socket) do
      Cham.EventBus.subscribe("pipeline")
      Cham.EventBus.subscribe("item")
    end
```

Add `handle_info` clauses to `lib/cham_web/live/item_detail_live.ex`:

```elixir
  @impl true
  def handle_info(event, socket) do
    item_id = socket.assigns.item.id

    if event_for_item?(event, item_id) do
      # Reload data
      item = Items.get_item!(item_id)
      artifacts = Items.list_artifacts(item_id)
      stage_history = Tracker.get_stage_history(item_id)
      progress = Tracker.get_progress(item_id)

      {:noreply,
       socket
       |> assign(:item, item)
       |> assign(:artifacts, artifacts)
       |> assign(:stage_history, stage_history)
       |> assign(:progress, progress)
       |> assign_content(item, artifacts, stage_history)}
    else
      {:noreply, socket}
    end
  end

  defp event_for_item?(%{item_id: event_item_id}, item_id), do: event_item_id == item_id
  defp event_for_item?(%{item: %{id: event_item_id}}, item_id), do: event_item_id == item_id
  defp event_for_item?(_, _), do: false
```

Also add `progress` assign to `mount/3`:

```elixir
     |> assign(:progress, Tracker.get_progress(item.id))
```

Add progress bars to the processing view in the template. In `lib/cham_web/live/item_detail_live.html.heex`, add after the stage history `div` inside the processing pipeline section:

```heex
      <%!-- Progress bars for active stages --%>
      <div :for={{stage_id, prog} <- @progress} class="mt-2">
        <div class="text-xs font-medium text-gray-600 mb-1">{stage_id}</div>
        <.progress_bar progress={prog.progress} message={prog.message} />
      </div>
```

- [ ] **Step 4: Run tests**

```bash
mix format
mix test test/cham_web/live/item_detail_live_test.exs
```

Expected: all tests pass.

- [ ] **Step 5: Run full test suite**

```bash
mix test
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: add real-time updates to item detail via EventBus

Subscribe to pipeline and item topics. Reload artifacts, stage history,
and progress on relevant events. Progress bars for active stages.
Non-disruptive updates via targeted assigns."
```

---

## Verification

After all tasks, run:

```bash
mix format --check-formatted
mix test
```

All should pass with zero warnings.
