# v3 Phase 0a — Teardown + Schema Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the v2 ingestion layer that the v3 schema breaks, land a fresh v3 Postgres migration, and add the six v3 Ecto schemas with changeset tests — leaving a compiling repo with `mix test` green.

**Architecture:** In-place rewrite on a branch (per the reconciliation doc's build strategy). This is the first of two Phase 0 plans; Plan 0b adds `Cham.Identity`, `Cham.Archive.Layout`, and the `Cham.Archive` context primitives. We tear out the v2 pipeline/plugins/UI/MCP-tools/chat/polling first (keeping infra: config, event bus, Oban, Repo, LiveView shell, ScriptRunner, subscriptions table/backends), then replace the `items`/`artifacts` tables and add `url_identities`/`snapshots`/`components`/`edges`.

**Tech Stack:** Elixir 1.19+, Phoenix 1.7, Ecto + PostgreSQL 16, ExUnit (`Cham.DataCase` for DB tests).

**Spec:** `docs/superpowers/specs/2026-06-01-v3-phase-0-data-model-substrate-design.md`
**Reconciliation:** `docs/superpowers/specs/2026-06-01-v3-ingestion-reconciliation-and-sequencing.md`

---

## Teardown decisions (read before starting)

The schema change drops `items.url`, `items.bootstrap_path`, `items.content_type` and re-keys `artifacts` from `item_id` to `snapshot_id`/`component_id`. Everything reading those breaks. The build strategy accepts a non-runnable app until the Phase 5 cutover, so we **remove** the broken v2 code rather than port it now.

**REMOVE (rebuilt in later phases):**
- The processing pipeline: `lib/cham/pipeline/` (all) and its tests.
- The v2 plugin runtime + plugins: `lib/cham/plugin.ex`, `lib/cham/plugin/`, `lib/cham/plugins/` and their tests.
- Item chat: `lib/cham/chat.ex` and its tests.
- v2 web UI/API tied to items: `item_controller.ex`, `item_json.ex`, `file_controller.ex`, `tag_controller.ex`, `event_controller.ex`, `lib/cham_web/live/dashboard_live*` (incl. `dashboard_live/`), `subscription_show_live.ex`, and their tests + routes.
- MCP item tools: `lib/cham/mcp/tools/get_article_markdown.ex`, `search_articles.ex` (and their `component(...)` registrations).
- Subscription item-creation: `lib/cham/subscriptions/poll_worker.ex` and its tests.
- Job-tracking reactor: `lib/cham/job_tracking/tracker.ex` and its tests.
- The v2 items context + caches + v2 schemas: `lib/cham/items.ex`, `lib/cham/items/` (all), and their tests.

**KEEP (infra):** `lib/cham/config/`, `lib/cham/event_bus.ex`, `lib/cham/repo.ex`, `lib/cham/release.ex`, `lib/cham/script_runner.ex`, Oban wiring, `lib/cham/subscriptions.ex` + `subscriptions/` (minus poll_worker) + RSS backend + `BackendRegistry` + `Supervisor`, `lib/cham/job_tracking/stage_execution.ex` (schema only), `lib/cham/mcp/server.ex` (with zero tools), the Phoenix shell (`endpoint.ex`, `telemetry.ex`, `components/`, `layouts`), `ConfigLive`, `SubscriptionIndexLive`, `HealthController`.

**Tables preserved by the migration (NOT dropped):** `oban_jobs`, `stage_executions`, `item_messages`, `subscriptions`. Only `items` and `artifacts` are dropped + recreated; the four new tables are added.

---

## Task 1: Remove the processing pipeline + plugin runtime

**Files:**
- Delete: `lib/cham/pipeline/` (all: `orchestrator.ex`, `stage_worker.ex`, `dag.ex`, `desired_stages.ex`, `label_matcher.ex`, `queue_scaler.ex`, `supervisor.ex`, `events.ex`), `lib/cham/pipeline.ex`
- Delete: `lib/cham/plugin.ex`, `lib/cham/plugin/` (all), `lib/cham/stage.ex`, `lib/cham/plugins/` (all)
- Delete tests: `test/cham/pipeline/` (all), `test/cham/plugins/` (all), any `test/cham/plugin*`
- Modify: `lib/cham/application.ex`

- [ ] **Step 1: Delete pipeline + plugin source and tests**

```bash
git rm -r lib/cham/pipeline lib/cham/pipeline.ex lib/cham/plugin lib/cham/plugin.ex lib/cham/stage.ex lib/cham/plugins
git rm -r test/cham/pipeline test/cham/plugins 2>/dev/null || true
git rm test/cham/plugin_test.exs test/cham/plugin/*_test.exs 2>/dev/null || true
```

- [ ] **Step 2: Rewrite `lib/cham/application.ex` to stop starting the removed trees**

Replace the entire file with:

```elixir
defmodule Cham.Application do
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    migrate()

    children = [
      ChamWeb.Telemetry,
      Cham.Repo,
      {DNSCluster, query: Application.get_env(:cham, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Cham.PubSub},
      {Cham.Config.Manager,
       toml_path: Application.get_env(:cham, :config_toml_path, "config/cham.toml"),
       event_bus: Cham.PubSub},
      Cham.Subscriptions.Supervisor,
      {Cham.MCP.Server, transport: :streamable_http},
      ChamWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Cham.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        register_display_config()
        Cham.Subscriptions.BackendRegistry.register(Cham.Subscriptions.Backends.RSS)
        register_subscription_backend_config(Cham.Subscriptions.Backends.RSS)
        {:ok, pid}

      error ->
        error
    end
  end

  defp migrate do
    unless Application.get_env(:cham, :skip_migrations, false) do
      ensure_database_created()

      {:ok, _, _} =
        Ecto.Migrator.with_repo(Cham.Repo, fn repo ->
          Ecto.Migrator.run(repo, :up, all: true)
        end)
    end
  end

  defp ensure_database_created do
    case Cham.Repo.__adapter__().storage_up(Cham.Repo.config()) do
      :ok -> Logger.info("Database created")
      {:error, :already_up} -> :ok
      {:error, reason} -> Logger.warning("Could not create database: #{inspect(reason)}")
    end
  end

  defp register_display_config do
    schema = [
      %{
        key: :thumbnail_provider_order,
        type: :string,
        default: "ffmpeg",
        description:
          "Comma-separated list of thumbnail providers in preference order. " <>
            "The first provider with an available artifact wins.",
        required: false,
        options: nil
      },
      %{
        key: :title_provider_order,
        type: :string,
        default: "clean_title",
        description:
          "Comma-separated list of title-override providers in preference order. " <>
            "Falls back to item.title when none match.",
        required: false,
        options: nil
      },
      %{
        key: :content_order,
        type: :string,
        default: "cleaned_content,content",
        description:
          "Comma-separated list of content artifact types to display for articles, in " <>
            "preference order. For each type, the derived artifact is preferred over the " <>
            "original. Known types: cleaned_content, content.",
        required: false,
        options: nil
      }
    ]

    case Cham.Config.Manager.register("display", schema) do
      :ok -> :ok
      {:error, :already_registered} -> :ok
      {:error, reason} -> Logger.warning("Failed to register display config: #{inspect(reason)}")
    end
  end

  defp register_subscription_backend_config(mod) do
    schema = if function_exported?(mod, :config_schema, 0), do: mod.config_schema(), else: []

    if schema != [] do
      namespace = "subscriptions.#{mod.id()}"

      case Cham.Config.Manager.register(namespace, schema) do
        :ok -> :ok
        {:error, :already_registered} -> :ok
        {:error, reason} ->
          Logger.warning("Failed to register config for backend #{mod.id()}: #{inspect(reason)}")
      end
    end
  end

  @impl true
  def config_change(changed, _new, removed) do
    ChamWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
```

Note: `Cham.Items.Cache`, `Cham.Items.StatsCache`, `Cham.Plugin.Registry`, `Cham.Pipeline.Supervisor`, and the plugin/pipeline/chat `register_*` calls are gone. `register_display_config` is retained because `display.*` is read by config UI infra; the others referenced now-deleted modules.

- [ ] **Step 3: Compile and resolve residual references**

Run: `mix compile --warnings-as-errors`
Expected: It will surface remaining references to the deleted modules from files this task does not own (e.g. MCP tools, web controllers, chat, poll_worker, tracker, items context). **Those are removed in Tasks 2–7.** For this task, the goal is that `application.ex`, `lib/cham/pipeline*`, `lib/cham/plugin*`, and `lib/cham/plugins*` are gone and no *kept infra* file references them. If a kept infra file (config, event_bus, subscriptions backends, mcp/server.ex) references a deleted pipeline/plugin module, remove that reference now.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "refactor(v3): remove v2 processing pipeline and plugin runtime"
```

---

## Task 2: Remove item chat

**Files:**
- Delete: `lib/cham/chat.ex`, any `lib/cham_web/live/*chat*`, `test/cham/chat_test.exs`
- Modify: `lib/cham/application.ex` (already done in Task 1 — `register_chat_config` was dropped; confirm no chat reference remains)

- [ ] **Step 1: Delete chat source and tests**

```bash
git rm lib/cham/chat.ex
git rm test/cham/chat_test.exs 2>/dev/null || true
git grep -l "Cham.Chat" lib test | xargs git rm 2>/dev/null || true
```

- [ ] **Step 2: Remove residual `Cham.Chat` references**

Run: `git grep -n "Cham.Chat"`
Expected: no matches. If any remain in kept files, delete those lines/files (they are chat UI or config wiring).

- [ ] **Step 3: Compile**

Run: `mix compile 2>&1 | grep -i "Cham.Chat"`
Expected: no output (chat fully removed; other unrelated errors from Tasks 3–7 are expected until those tasks land).

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "refactor(v3): remove item chat (returns as a research-pane panel in Phase 7)"
```

---

## Task 3: Remove v2 item-coupled web UI/API + routes

**Files:**
- Delete: `lib/cham_web/controllers/item_controller.ex`, `item_json.ex`, `file_controller.ex`, `tag_controller.ex`, `event_controller.ex`
- Delete: `lib/cham_web/live/dashboard_live.ex`, `dashboard_live.html.heex`, `lib/cham_web/live/dashboard_live/` (all), `lib/cham_web/live/subscription_show_live.ex`
- Delete their tests under `test/cham_web/`
- Modify: `lib/cham_web/router.ex`

- [ ] **Step 1: Delete the controllers, LiveViews, and tests**

```bash
git rm lib/cham_web/controllers/item_controller.ex lib/cham_web/controllers/item_json.ex \
       lib/cham_web/controllers/file_controller.ex lib/cham_web/controllers/tag_controller.ex \
       lib/cham_web/controllers/event_controller.ex
git rm -r lib/cham_web/live/dashboard_live.ex lib/cham_web/live/dashboard_live.html.heex lib/cham_web/live/dashboard_live
git rm lib/cham_web/live/subscription_show_live.ex
git rm test/cham_web/controllers/item_controller_test.exs test/cham_web/controllers/file_controller_test.exs \
       test/cham_web/controllers/tag_controller_test.exs test/cham_web/controllers/event_controller_test.exs 2>/dev/null || true
git rm test/cham_web/live/dashboard_live_test.exs test/cham_web/live/subscription_show_live_test.exs 2>/dev/null || true
```

- [ ] **Step 2: Rewrite `lib/cham_web/router.ex` to drop the removed routes**

Replace the entire file with:

```elixir
defmodule ChamWeb.Router do
  use ChamWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ChamWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", ChamWeb do
    pipe_through :browser

    live "/config", ConfigLive
    live "/subscriptions", SubscriptionIndexLive
  end

  scope "/", ChamWeb do
    pipe_through :api
    get "/health", HealthController, :index
  end

  scope "/mcp" do
    pipe_through :api
    forward "/", Anubis.Server.Transport.StreamableHTTP.Plug, server: Cham.MCP.Server
  end

  if Application.compile_env(:cham, :dev_routes, Mix.env() == :dev) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard",
        metrics: ChamWeb.Telemetry,
        ecto_repos: [Cham.Repo],
        ecto_psql_extras_options: [long_running_queries: [threshold: "200 milliseconds"]]
    end
  end
end
```

Note: removed the `/` DashboardLive index + `/items/:id` detail, all `/api/v1/items*`, `/api/v1/tags/clear`, and the file-serving route. Kept `ConfigLive`, `SubscriptionIndexLive`, `/health`, MCP, and dev dashboard. There is intentionally **no root `/` page** during the rebuild; it returns in Phase 7.

- [ ] **Step 3: Compile and resolve residual web references**

Run: `mix compile 2>&1 | grep -iE "DashboardLive|ItemController|FileController|TagController|EventController|SubscriptionShowLive"`
Expected: no output. If `subscription_index_live.ex` references the removed `SubscriptionShowLive` (e.g. a `~p"/subscriptions/#{id}"` link), remove that link/navigation.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "refactor(v3): remove v2 item web UI/API and routes"
```

---

## Task 4: Remove MCP item tools (keep the server)

**Files:**
- Delete: `lib/cham/mcp/tools/get_article_markdown.ex`, `lib/cham/mcp/tools/search_articles.ex`, their tests
- Modify: `lib/cham/mcp/server.ex`

- [ ] **Step 1: Delete the tools and tests**

```bash
git rm lib/cham/mcp/tools/get_article_markdown.ex lib/cham/mcp/tools/search_articles.ex
git rm test/cham/mcp/tools/get_article_markdown_test.exs test/cham/mcp/tools/search_articles_test.exs 2>/dev/null || true
```

- [ ] **Step 2: Remove the `component(...)` registrations in `lib/cham/mcp/server.ex`**

Delete these two lines:

```elixir
  component(Cham.MCP.Tools.GetArticleMarkdown)
  component(Cham.MCP.Tools.SearchArticles)
```

Leave the rest of the module intact (the server keeps `capabilities: [:tools]` with zero tools registered — valid; item tools return in a later phase).

- [ ] **Step 3: Compile**

Run: `mix compile 2>&1 | grep -iE "GetArticleMarkdown|SearchArticles"`
Expected: no output.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "refactor(v3): remove item-coupled MCP tools"
```

---

## Task 5: Remove subscription polling that creates items

**Files:**
- Delete: `lib/cham/subscriptions/poll_worker.ex`, `test/cham/subscriptions/poll_worker_test.exs`
- Modify: `lib/cham/subscriptions.ex` (remove any enqueue/reference to `PollWorker`)

- [ ] **Step 1: Delete the poll worker and its test**

```bash
git rm lib/cham/subscriptions/poll_worker.ex
git rm test/cham/subscriptions/poll_worker_test.exs 2>/dev/null || true
```

- [ ] **Step 2: Remove `PollWorker` references from the subscriptions context**

Run: `git grep -n "PollWorker"`
Expected after edits: no matches. In `lib/cham/subscriptions.ex`, delete any function that enqueues `PollWorker` (e.g. `enqueue_poll/1`) and any call site. The subscriptions **table, schema, context CRUD, and RSS backend remain**; only the item-creating poll path is removed (re-wired to the v3 submit path in Phase 3/4).

- [ ] **Step 3: Compile**

Run: `mix compile 2>&1 | grep -i "PollWorker"`
Expected: no output.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "refactor(v3): remove subscription poll worker (re-wired to v3 submit path later)"
```

---

## Task 6: Remove the job-tracking reactor (keep the StageExecution schema)

**Files:**
- Delete: `lib/cham/job_tracking/tracker.ex`, `test/cham/job_tracking/tracker_test.exs`
- Keep: `lib/cham/job_tracking/stage_execution.ex` (schema only)
- Modify: any references to `Cham.JobTracking.Tracker`

- [ ] **Step 1: Delete the tracker and its test**

```bash
git rm lib/cham/job_tracking/tracker.ex
git rm test/cham/job_tracking/tracker_test.exs 2>/dev/null || true
```

- [ ] **Step 2: Remove `Cham.JobTracking.Tracker` references**

Run: `git grep -n "JobTracking.Tracker"`
Expected: no matches. Remove any remaining references (the tracker subscribed to pipeline events, which are gone). `Cham.JobTracking.StageExecution` (the schema) stays.

- [ ] **Step 3: Compile**

Run: `mix compile 2>&1 | grep -i "JobTracking.Tracker"`
Expected: no output.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "refactor(v3): remove job-tracking reactor (keep StageExecution schema)"
```

---

## Task 7: Remove the v2 items context, caches, and schemas

**Files:**
- Delete: `lib/cham/items.ex`, `lib/cham/items/cache.ex`, `lib/cham/items/stats_cache.ex`, `lib/cham/items/events.ex`, `lib/cham/items/item.ex`, `lib/cham/items/artifact.ex`, `lib/cham/items/item_message.ex`
- Delete their tests under `test/cham/items/` and `test/cham/items_test.exs`

- [ ] **Step 1: Delete the v2 items context, caches, and schemas**

```bash
git rm -r lib/cham/items lib/cham/items.ex
git rm -r test/cham/items test/cham/items_test.exs 2>/dev/null || true
```

Note: `Cham.Items.ItemMessage` (the chat-storage schema) is removed too — chat returns in Phase 7. The `item_messages` **table** is preserved by the migration (Task 8); the schema module is re-introduced when chat returns.

- [ ] **Step 2: Compile the whole project clean**

Run: `mix compile --warnings-as-errors`
Expected: **PASS.** All v2 ingestion consumers are now gone. If any reference to `Cham.Items*` remains, run `git grep -n "Cham.Items"` and remove the offending line/file (it belongs to deleted UI/CLI).

- [ ] **Step 3: Run the remaining test suite**

Run: `mix test`
Expected: PASS (only infra tests remain: config, event_bus, script_runner, subscriptions context, mcp server). Delete any orphaned test that still references removed modules.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "refactor(v3): remove v2 items context, caches, and schemas"
```

---

## Task 8: v3 schema migration

**Files:**
- Create: `priv/repo/migrations/20260601120000_v3_schema_reset.exs`
- Test: (verified via `mix ecto.migrate` + the schema tests in Tasks 9–14)

- [ ] **Step 1: Write the migration**

Create `priv/repo/migrations/20260601120000_v3_schema_reset.exs`:

```elixir
defmodule Cham.Repo.Migrations.V3SchemaReset do
  use Ecto.Migration

  @moduledoc """
  Fresh v3 data-model schema. Drops the v2 `items` and `artifacts` tables
  (CASCADE removes dependent FK constraints on stage_executions / item_messages,
  which are otherwise preserved) and creates the v3 six: items, url_identities,
  snapshots, components, artifacts, edges. Re-adds the item_id FKs on the
  preserved tables. oban_jobs / stage_executions / item_messages / subscriptions
  are NOT dropped.
  """

  def up do
    # Drop v2 tables. CASCADE drops the FK constraints on stage_executions /
    # item_messages that point at items; those tables and their columns survive.
    execute "DROP TABLE IF EXISTS artifacts CASCADE"
    execute "DROP TABLE IF EXISTS items CASCADE"

    create table(:items, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :slug, :text
      add :title, :text
      add :status, :text, null: false, default: "bootstrapping"
      add :archive_path, :text, null: false
      add :first_captured_at, :utc_datetime, null: false
      add :tags, {:array, :text}, default: []
      add :metadata, :map, default: %{}
      add :search_vector, :tsvector

      timestamps(type: :utc_datetime)
    end

    create unique_index(:items, [:archive_path])
    create index(:items, [:status])
    create index(:items, [:first_captured_at])
    create index(:items, [:tags], using: :gin)
    create index(:items, [:search_vector], using: :gin)

    create table(:url_identities, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :item_id, references(:items, type: :binary_id, on_delete: :delete_all), null: false
      add :url_hash, :text, null: false
      add :normalized_url, :text, null: false
      add :role, :text, null: false

      add :inserted_at, :utc_datetime, null: false, default: fragment("now()")
    end

    create unique_index(:url_identities, [:url_hash])
    create index(:url_identities, [:item_id])

    create table(:snapshots, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :item_id, references(:items, type: :binary_id, on_delete: :delete_all), null: false
      add :captured_at, :utc_datetime, null: false
      add :provenance, :map, default: %{}
      add :snapshot_path, :text, null: false

      add :inserted_at, :utc_datetime, null: false, default: fragment("now()")
    end

    create index(:snapshots, [:item_id])
    create index(:snapshots, [:captured_at])

    create table(:components, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :snapshot_id, references(:snapshots, type: :binary_id, on_delete: :delete_all), null: false
      add :content_type, :text, null: false

      add :inserted_at, :utc_datetime, null: false, default: fragment("now()")
    end

    create unique_index(:components, [:snapshot_id, :content_type])
    create index(:components, [:snapshot_id])

    create table(:artifacts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :snapshot_id, references(:snapshots, type: :binary_id, on_delete: :delete_all), null: false
      add :component_id, references(:components, type: :binary_id, on_delete: :delete_all)
      add :category, :text, null: false
      add :stage, :text, null: false
      add :labels, :map, null: false, default: %{}
      add :filenames, {:array, :text}, default: []
      add :path, :text, null: false
      add :status, :text, null: false, default: "produced"
      add :version, :integer
      add :started_at, :utc_datetime
      add :ended_at, :utc_datetime
    end

    create index(:artifacts, [:snapshot_id])
    create index(:artifacts, [:component_id])
    create index(:artifacts, [:labels], using: :gin)
    create index(:artifacts, [:status])

    create table(:edges, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :source_item_id, references(:items, type: :binary_id, on_delete: :delete_all), null: false
      add :edge_type, :text, null: false
      add :target_url_hash, :text, null: false
      add :target_item_id, references(:items, type: :binary_id, on_delete: :nilify_all)
      add :provenance, :text, null: false

      add :inserted_at, :utc_datetime, null: false, default: fragment("now()")
    end

    create index(:edges, [:source_item_id])
    create index(:edges, [:target_url_hash])
    create index(:edges, [:target_item_id])

    # Re-establish FKs on preserved tables that pointed at the old items table.
    # IF EXISTS guards make this safe whether or not the columns/constraints survived.
    execute """
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_name = 'stage_executions' AND column_name = 'item_id') THEN
        ALTER TABLE stage_executions
          ADD CONSTRAINT stage_executions_item_id_fkey
          FOREIGN KEY (item_id) REFERENCES items(id) ON DELETE CASCADE;
      END IF;
      IF EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_name = 'item_messages' AND column_name = 'item_id') THEN
        ALTER TABLE item_messages
          ADD CONSTRAINT item_messages_item_id_fkey
          FOREIGN KEY (item_id) REFERENCES items(id) ON DELETE CASCADE;
      END IF;
    END $$;
    """
  end

  def down do
    raise Ecto.MigrationError,
      message: "v3_schema_reset is a one-way fresh-schema migration; rebuild from archive instead"
  end
end
```

- [ ] **Step 2: Run the migration against dev and test databases**

Run: `mix ecto.migrate && MIX_ENV=test mix ecto.migrate`
Expected: both succeed; output shows the six `create table` operations and the FK re-establishment.

- [ ] **Step 3: Verify the schema in psql**

Run: `psql "$(mix run -e 'IO.puts(Cham.Repo.config()[:url] || "")' 2>/dev/null)" -c "\\d items" 2>/dev/null || mix ecto.dump`
Expected: `items` has no `url`/`bootstrap_path`/`content_type` columns; `url_identities`, `snapshots`, `components`, `edges` exist. (If the URL form fails locally, `mix ecto.dump` writing `priv/repo/structure.sql` is sufficient confirmation.)

- [ ] **Step 4: Commit**

```bash
git add priv/repo/migrations/20260601120000_v3_schema_reset.exs priv/repo/structure.sql 2>/dev/null
git add -A
git commit -m "feat(v3): fresh v3 data-model schema migration"
```

---

## Task 9: `Cham.Archive.Item` schema

**Files:**
- Create: `lib/cham/archive/item.ex`
- Test: `test/cham/archive/item_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/cham/archive/item_test.exs`:

```elixir
defmodule Cham.Archive.ItemTest do
  use Cham.DataCase, async: true

  alias Cham.Archive.Item

  @valid %{
    slug: "ingest-a1b2c3d4",
    status: "bootstrapping",
    archive_path: "2026/06/01/ingest-a1b2c3d4",
    first_captured_at: ~U[2026-06-01 12:00:00Z]
  }

  test "create_changeset accepts valid attrs" do
    assert %{valid?: true} = Item.create_changeset(%Item{}, @valid)
  end

  test "create_changeset requires archive_path and first_captured_at" do
    cs = Item.create_changeset(%Item{}, Map.drop(@valid, [:archive_path, :first_captured_at]))
    refute cs.valid?
    assert %{archive_path: _, first_captured_at: _} = errors_on(cs)
  end

  test "rejects an unknown status" do
    cs = Item.create_changeset(%Item{}, %{@valid | status: "archived"})
    refute cs.valid?
    assert %{status: _} = errors_on(cs)
  end

  test "enforces unique archive_path" do
    {:ok, _} = %Item{} |> Item.create_changeset(@valid) |> Repo.insert()
    {:error, cs} = %Item{} |> Item.create_changeset(@valid) |> Repo.insert()
    assert %{archive_path: _} = errors_on(cs)
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/cham/archive/item_test.exs`
Expected: FAIL — `Cham.Archive.Item` is undefined.

- [ ] **Step 3: Write the schema**

Create `lib/cham/archive/item.ex`:

```elixir
defmodule Cham.Archive.Item do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  @statuses ~w(bootstrapping extracting processing complete incomplete failed)

  schema "items" do
    field :slug, :string
    field :title, :string
    field :status, :string, default: "bootstrapping"
    field :archive_path, :string
    field :first_captured_at, :utc_datetime
    field :tags, {:array, :string}, default: []
    field :metadata, :map, default: %{}

    has_many :url_identities, Cham.Archive.UrlIdentity
    has_many :snapshots, Cham.Archive.Snapshot

    timestamps(type: :utc_datetime)
  end

  def create_changeset(item, attrs) do
    item
    |> cast(attrs, [:slug, :title, :status, :archive_path, :first_captured_at, :tags, :metadata])
    |> validate_required([:slug, :archive_path, :first_captured_at])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:archive_path)
  end

  def update_changeset(item, attrs) do
    item
    |> cast(attrs, [:slug, :title, :status, :archive_path, :tags, :metadata])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:archive_path)
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/cham/archive/item_test.exs`
Expected: PASS (4 tests). The `has_many` references to `UrlIdentity`/`Snapshot` are defined in Tasks 10 and 11; Elixir resolves module references lazily, so this compiles before those exist — but if you run the full suite now it still passes.

- [ ] **Step 5: Commit**

```bash
git add lib/cham/archive/item.ex test/cham/archive/item_test.exs
git commit -m "feat(v3): Cham.Archive.Item schema"
```

---

## Task 10: `Cham.Archive.UrlIdentity` schema

**Files:**
- Create: `lib/cham/archive/url_identity.ex`
- Test: `test/cham/archive/url_identity_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/cham/archive/url_identity_test.exs`:

```elixir
defmodule Cham.Archive.UrlIdentityTest do
  use Cham.DataCase, async: true

  alias Cham.Archive.{Item, UrlIdentity}

  defp item_fixture do
    {:ok, item} =
      %Item{}
      |> Item.create_changeset(%{
        slug: "ingest-a1b2c3d4",
        archive_path: "2026/06/01/ingest-a1b2c3d4",
        first_captured_at: ~U[2026-06-01 12:00:00Z]
      })
      |> Repo.insert()

    item
  end

  defp valid(item) do
    %{
      item_id: item.id,
      url_hash: "deadbeef",
      normalized_url: "https://example.com/a",
      role: "submitted"
    }
  end

  test "accepts valid attrs" do
    item = item_fixture()
    assert %{valid?: true} = UrlIdentity.changeset(%UrlIdentity{}, valid(item))
  end

  test "rejects an unknown role" do
    item = item_fixture()
    cs = UrlIdentity.changeset(%UrlIdentity{}, %{valid(item) | role: "canonical"})
    refute cs.valid?
    assert %{role: _} = errors_on(cs)
  end

  test "enforces unique url_hash" do
    item = item_fixture()
    {:ok, _} = %UrlIdentity{} |> UrlIdentity.changeset(valid(item)) |> Repo.insert()
    {:error, cs} = %UrlIdentity{} |> UrlIdentity.changeset(valid(item)) |> Repo.insert()
    assert %{url_hash: _} = errors_on(cs)
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/cham/archive/url_identity_test.exs`
Expected: FAIL — `Cham.Archive.UrlIdentity` is undefined.

- [ ] **Step 3: Write the schema**

Create `lib/cham/archive/url_identity.ex`:

```elixir
defmodule Cham.Archive.UrlIdentity do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  @roles ~w(submitted redirect_alias)

  schema "url_identities" do
    field :url_hash, :string
    field :normalized_url, :string
    field :role, :string

    belongs_to :item, Cham.Archive.Item

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(identity, attrs) do
    identity
    |> cast(attrs, [:item_id, :url_hash, :normalized_url, :role])
    |> validate_required([:item_id, :url_hash, :normalized_url, :role])
    |> validate_inclusion(:role, @roles)
    |> unique_constraint(:url_hash)
    |> foreign_key_constraint(:item_id)
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/cham/archive/url_identity_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/cham/archive/url_identity.ex test/cham/archive/url_identity_test.exs
git commit -m "feat(v3): Cham.Archive.UrlIdentity schema"
```

---

## Task 11: `Cham.Archive.Snapshot` schema

**Files:**
- Create: `lib/cham/archive/snapshot.ex`
- Test: `test/cham/archive/snapshot_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/cham/archive/snapshot_test.exs`:

```elixir
defmodule Cham.Archive.SnapshotTest do
  use Cham.DataCase, async: true

  alias Cham.Archive.{Item, Snapshot}

  defp item_fixture do
    {:ok, item} =
      %Item{}
      |> Item.create_changeset(%{
        slug: "ingest-a1b2c3d4",
        archive_path: "2026/06/01/ingest-a1b2c3d4",
        first_captured_at: ~U[2026-06-01 12:00:00Z]
      })
      |> Repo.insert()

    item
  end

  test "accepts valid attrs and stores provenance map" do
    item = item_fixture()

    attrs = %{
      item_id: item.id,
      captured_at: ~U[2026-06-01 12:00:00Z],
      snapshot_path: "snapshots/20260601T120000Z/",
      provenance: %{"kind" => "cli", "agent" => "cham-cli/0.1"}
    }

    {:ok, snap} = %Snapshot{} |> Snapshot.changeset(attrs) |> Repo.insert()
    assert snap.provenance["kind"] == "cli"
  end

  test "requires item_id, captured_at, snapshot_path" do
    cs = Snapshot.changeset(%Snapshot{}, %{})
    refute cs.valid?
    assert %{item_id: _, captured_at: _, snapshot_path: _} = errors_on(cs)
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/cham/archive/snapshot_test.exs`
Expected: FAIL — `Cham.Archive.Snapshot` is undefined.

- [ ] **Step 3: Write the schema**

Create `lib/cham/archive/snapshot.ex`:

```elixir
defmodule Cham.Archive.Snapshot do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "snapshots" do
    field :captured_at, :utc_datetime
    field :provenance, :map, default: %{}
    field :snapshot_path, :string

    belongs_to :item, Cham.Archive.Item
    has_many :components, Cham.Archive.Component
    has_many :artifacts, Cham.Archive.Artifact

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [:item_id, :captured_at, :provenance, :snapshot_path])
    |> validate_required([:item_id, :captured_at, :snapshot_path])
    |> foreign_key_constraint(:item_id)
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/cham/archive/snapshot_test.exs`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/cham/archive/snapshot.ex test/cham/archive/snapshot_test.exs
git commit -m "feat(v3): Cham.Archive.Snapshot schema"
```

---

## Task 12: `Cham.Archive.Component` schema

**Files:**
- Create: `lib/cham/archive/component.ex`
- Test: `test/cham/archive/component_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/cham/archive/component_test.exs`:

```elixir
defmodule Cham.Archive.ComponentTest do
  use Cham.DataCase, async: true

  alias Cham.Archive.{Component, Item, Snapshot}

  defp snapshot_fixture do
    {:ok, item} =
      %Item{}
      |> Item.create_changeset(%{
        slug: "ingest-a1b2c3d4",
        archive_path: "2026/06/01/ingest-a1b2c3d4",
        first_captured_at: ~U[2026-06-01 12:00:00Z]
      })
      |> Repo.insert()

    {:ok, snap} =
      %Snapshot{}
      |> Snapshot.changeset(%{
        item_id: item.id,
        captured_at: ~U[2026-06-01 12:00:00Z],
        snapshot_path: "snapshots/20260601T120000Z/"
      })
      |> Repo.insert()

    snap
  end

  test "accepts valid attrs" do
    snap = snapshot_fixture()
    cs = Component.changeset(%Component{}, %{snapshot_id: snap.id, content_type: "article"})
    assert cs.valid?
  end

  test "enforces one component per type per snapshot" do
    snap = snapshot_fixture()
    attrs = %{snapshot_id: snap.id, content_type: "article"}
    {:ok, _} = %Component{} |> Component.changeset(attrs) |> Repo.insert()
    {:error, cs} = %Component{} |> Component.changeset(attrs) |> Repo.insert()
    assert %{snapshot_id: _} = errors_on(cs)
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/cham/archive/component_test.exs`
Expected: FAIL — `Cham.Archive.Component` is undefined.

- [ ] **Step 3: Write the schema**

Create `lib/cham/archive/component.ex`:

```elixir
defmodule Cham.Archive.Component do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "components" do
    field :content_type, :string

    belongs_to :snapshot, Cham.Archive.Snapshot
    has_many :artifacts, Cham.Archive.Artifact

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(component, attrs) do
    component
    |> cast(attrs, [:snapshot_id, :content_type])
    |> validate_required([:snapshot_id, :content_type])
    |> unique_constraint([:snapshot_id, :content_type],
      name: :components_snapshot_id_content_type_index
    )
    |> foreign_key_constraint(:snapshot_id)
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/cham/archive/component_test.exs`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/cham/archive/component.ex test/cham/archive/component_test.exs
git commit -m "feat(v3): Cham.Archive.Component schema"
```

---

## Task 13: `Cham.Archive.Artifact` schema

**Files:**
- Create: `lib/cham/archive/artifact.ex`
- Test: `test/cham/archive/artifact_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/cham/archive/artifact_test.exs`:

```elixir
defmodule Cham.Archive.ArtifactTest do
  use Cham.DataCase, async: true

  alias Cham.Archive.{Artifact, Item, Snapshot}

  defp snapshot_fixture do
    {:ok, item} =
      %Item{}
      |> Item.create_changeset(%{
        slug: "ingest-a1b2c3d4",
        archive_path: "2026/06/01/ingest-a1b2c3d4",
        first_captured_at: ~U[2026-06-01 12:00:00Z]
      })
      |> Repo.insert()

    {:ok, snap} =
      %Snapshot{}
      |> Snapshot.changeset(%{
        item_id: item.id,
        captured_at: ~U[2026-06-01 12:00:00Z],
        snapshot_path: "snapshots/20260601T120000Z/"
      })
      |> Repo.insert()

    snap
  end

  test "accepts a snapshot-level capture artifact (no component)" do
    snap = snapshot_fixture()

    attrs = %{
      snapshot_id: snap.id,
      category: "capture",
      stage: "passe_partout_capture",
      path: "capture/stages/passe_partout_capture-20260601T120005Z/",
      filenames: ["capture.warc.gz", "capture.cdxj"],
      labels: %{"type" => "capture", "format" => "warc"},
      status: "produced",
      version: 1
    }

    {:ok, art} = %Artifact{} |> Artifact.changeset(attrs) |> Repo.insert()
    assert art.component_id == nil
    assert art.filenames == ["capture.warc.gz", "capture.cdxj"]
  end

  test "rejects unknown category and status" do
    snap = snapshot_fixture()
    base = %{snapshot_id: snap.id, stage: "x", path: "p"}

    bad_cat = Artifact.changeset(%Artifact{}, Map.put(base, :category, "bogus"))
    refute bad_cat.valid?
    assert %{category: _} = errors_on(bad_cat)

    bad_status =
      Artifact.changeset(%Artifact{}, Map.merge(base, %{category: "extracted", status: "weird"}))

    refute bad_status.valid?
    assert %{status: _} = errors_on(bad_status)
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/cham/archive/artifact_test.exs`
Expected: FAIL — `Cham.Archive.Artifact` is undefined.

- [ ] **Step 3: Write the schema**

Create `lib/cham/archive/artifact.ex`:

```elixir
defmodule Cham.Archive.Artifact do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  @categories ~w(capture extracted derived)
  @statuses ~w(produced failed not_applicable)

  schema "artifacts" do
    field :category, :string
    field :stage, :string
    field :labels, :map, default: %{}
    field :filenames, {:array, :string}, default: []
    field :path, :string
    field :status, :string, default: "produced"
    field :version, :integer
    field :started_at, :utc_datetime
    field :ended_at, :utc_datetime

    belongs_to :snapshot, Cham.Archive.Snapshot
    belongs_to :component, Cham.Archive.Component
  end

  def changeset(artifact, attrs) do
    artifact
    |> cast(attrs, [
      :snapshot_id,
      :component_id,
      :category,
      :stage,
      :labels,
      :filenames,
      :path,
      :status,
      :version,
      :started_at,
      :ended_at
    ])
    |> validate_required([:snapshot_id, :category, :stage, :path])
    |> validate_inclusion(:category, @categories)
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:snapshot_id)
    |> foreign_key_constraint(:component_id)
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/cham/archive/artifact_test.exs`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/cham/archive/artifact.ex test/cham/archive/artifact_test.exs
git commit -m "feat(v3): Cham.Archive.Artifact schema"
```

---

## Task 14: `Cham.Archive.Edge` schema

**Files:**
- Create: `lib/cham/archive/edge.ex`
- Test: `test/cham/archive/edge_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/cham/archive/edge_test.exs`:

```elixir
defmodule Cham.Archive.EdgeTest do
  use Cham.DataCase, async: true

  alias Cham.Archive.{Edge, Item}

  defp item_fixture do
    {:ok, item} =
      %Item{}
      |> Item.create_changeset(%{
        slug: "ingest-a1b2c3d4",
        archive_path: "2026/06/01/ingest-a1b2c3d4",
        first_captured_at: ~U[2026-06-01 12:00:00Z]
      })
      |> Repo.insert()

    item
  end

  test "accepts a dangling edge (no target_item_id)" do
    item = item_fixture()

    attrs = %{
      source_item_id: item.id,
      edge_type: "linked",
      target_url_hash: "cafebabe",
      provenance: "extractor"
    }

    {:ok, edge} = %Edge{} |> Edge.changeset(attrs) |> Repo.insert()
    assert edge.target_item_id == nil
  end

  test "rejects unknown edge_type and provenance" do
    item = item_fixture()
    base = %{source_item_id: item.id, target_url_hash: "abc"}

    bad_type = Edge.changeset(%Edge{}, Map.merge(base, %{edge_type: "wat", provenance: "extractor"}))
    refute bad_type.valid?
    assert %{edge_type: _} = errors_on(bad_type)

    bad_prov = Edge.changeset(%Edge{}, Map.merge(base, %{edge_type: "embed", provenance: "robot"}))
    refute bad_prov.valid?
    assert %{provenance: _} = errors_on(bad_prov)
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/cham/archive/edge_test.exs`
Expected: FAIL — `Cham.Archive.Edge` is undefined.

- [ ] **Step 3: Write the schema**

Create `lib/cham/archive/edge.ex`:

```elixir
defmodule Cham.Archive.Edge do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  @edge_types ~w(embed linked mirror)
  @provenances ~w(extractor user)

  schema "edges" do
    field :edge_type, :string
    field :target_url_hash, :string
    field :provenance, :string

    belongs_to :source_item, Cham.Archive.Item
    belongs_to :target_item, Cham.Archive.Item

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(edge, attrs) do
    edge
    |> cast(attrs, [:source_item_id, :edge_type, :target_url_hash, :target_item_id, :provenance])
    |> validate_required([:source_item_id, :edge_type, :target_url_hash, :provenance])
    |> validate_inclusion(:edge_type, @edge_types)
    |> validate_inclusion(:provenance, @provenances)
    |> foreign_key_constraint(:source_item_id)
    |> foreign_key_constraint(:target_item_id)
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/cham/archive/edge_test.exs`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/cham/archive/edge.ex test/cham/archive/edge_test.exs
git commit -m "feat(v3): Cham.Archive.Edge schema"
```

---

## Task 15: Full-suite green gate

**Files:** none (verification only)

- [ ] **Step 1: Compile with warnings as errors**

Run: `mix compile --warnings-as-errors`
Expected: PASS, no warnings. If a warning names a removed module, remove the dead reference.

- [ ] **Step 2: Run the entire test suite**

Run: `mix test`
Expected: PASS. The suite is now infra tests + the six Archive schema tests. No references to removed v2 modules remain.

- [ ] **Step 3: Verify no v2 ingestion modules linger**

Run: `git grep -nE "Cham\\.(Items|Pipeline|Plugin|Plugins|Chat|JobTracking\\.Tracker)\\b" lib`
Expected: no matches (the `Cham.JobTracking.StageExecution` schema is allowed; the regex excludes it by matching `Tracker` specifically).

- [ ] **Step 4: Commit (if any cleanup was needed)**

```bash
git add -A
git commit -m "chore(v3): phase 0a green gate — compile clean, tests pass" --allow-empty
```

---

## Done

After Task 15: the repo compiles warning-free, `mix test` is green, the v2 ingestion layer is gone, and the v3 schema + six `Cham.Archive.*` Ecto schemas are in place. **Plan 0b** adds `Cham.Identity`, `Cham.Archive.Layout`, and the `Cham.Archive` context primitives (`create_item_with_identity`, `lookup_item_by_url`, `re_slugify`, …) on this substrate.
