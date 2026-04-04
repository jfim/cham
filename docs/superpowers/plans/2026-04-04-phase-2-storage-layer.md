# Phase 2: Storage Layer — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Storage Layer — database schema (items, artifacts, stage_executions, item_messages) with an Items context module, and the Archive & Storage subsystem (Filesystem Manager, Archive Manager, Metadata Manager) that manages the filesystem archive.

**Architecture:** PostgreSQL is a rebuildable index over the filesystem archive. Ecto schemas model the database tables. The archive subsystem has three layers: Filesystem Manager (generic FS ops), Archive Manager (archive-aware paths/layout), and Metadata Manager (artifact.json parsing/merging). The database and archive sides are mostly independent — they come together during reindexing (deferred to a later phase).

**Tech Stack:** Ecto 3.x, PostgreSQL 16+, Jason for JSON parsing

---

## File Structure

### New Files

| File | Responsibility |
|------|---------------|
| `lib/cham/items/item.ex` | Ecto schema for items table |
| `lib/cham/items/artifact.ex` | Ecto schema for artifacts table |
| `lib/cham/items/item_message.ex` | Ecto schema for item_messages table |
| `lib/cham/job_tracking/stage_execution.ex` | Ecto schema for stage_executions table |
| `lib/cham/items.ex` | Items context — CRUD for items and artifacts |
| `lib/cham/archive/filesystem_manager.ex` | Generic filesystem ops: mkdir_p, atomic_write, move |
| `lib/cham/archive/archive_manager.ex` | Archive-aware ops: path resolution, stage dirs, bootstrap→archive move |
| `lib/cham/archive/metadata_manager.ex` | artifact.json reading, cross-stage merging, metadata queries |
| `priv/repo/migrations/XXXX_create_items.exs` | Migration for items table with indexes |
| `priv/repo/migrations/XXXX_create_artifacts.exs` | Migration for artifacts table with indexes |
| `priv/repo/migrations/XXXX_create_stage_executions.exs` | Migration for stage_executions table |
| `priv/repo/migrations/XXXX_create_item_messages.exs` | Migration for item_messages table |
| `test/cham/items_test.exs` | Tests for Items context |
| `test/cham/archive/filesystem_manager_test.exs` | Tests for Filesystem Manager |
| `test/cham/archive/archive_manager_test.exs` | Tests for Archive Manager |
| `test/cham/archive/metadata_manager_test.exs` | Tests for Metadata Manager |

### Parallelism

The database side (Tasks 1-3) and archive side (Tasks 4-6) are independent. Within each side, tasks are sequential:

```
Task 1 (migrations) → Task 2 (schemas) → Task 3 (context)
Task 4 (filesystem mgr) → Task 5 (archive mgr) → Task 6 (metadata mgr)
```

Tasks 1+4, 2+5, and 3+6 can run in parallel.

---

## Task 1: Database Migrations

**Files:**
- Create: `priv/repo/migrations/XXXX_create_items.exs`
- Create: `priv/repo/migrations/XXXX_create_artifacts.exs`
- Create: `priv/repo/migrations/XXXX_create_stage_executions.exs`
- Create: `priv/repo/migrations/XXXX_create_item_messages.exs`

- [ ] **Step 1: Generate migrations**

```bash
cd /home/jfim/projects/cham-v2
mix ecto.gen.migration create_items
mix ecto.gen.migration create_artifacts
mix ecto.gen.migration create_stage_executions
mix ecto.gen.migration create_item_messages
```

- [ ] **Step 2: Write the items migration**

Edit the generated `create_items` migration:

```elixir
defmodule Cham.Repo.Migrations.CreateItems do
  use Ecto.Migration

  def change do
    create table(:items, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :url, :text, null: false
      add :status, :text, null: false, default: "bootstrapping"
      add :title, :text
      add :slug, :text
      add :content_type, :text
      add :bootstrap_path, :text
      add :archive_path, :text
      add :tags, {:array, :text}, default: []
      add :error_message, :text
      add :metadata, :map, default: %{}
      add :search_vector, :tsvector

      timestamps(type: :utc_datetime)
    end

    create unique_index(:items, [:url])
    create unique_index(:items, [:slug], where: "slug IS NOT NULL")
    create index(:items, [:status])
    create index(:items, [:tags], using: :gin)
    create index(:items, [:search_vector], using: :gin)
    create index(:items, [:inserted_at])
    create index(:items, [:content_type])
  end
end
```

- [ ] **Step 3: Write the artifacts migration**

```elixir
defmodule Cham.Repo.Migrations.CreateArtifacts do
  use Ecto.Migration

  def change do
    create table(:artifacts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :item_id, references(:items, type: :binary_id, on_delete: :delete_all), null: false
      add :stage, :text, null: false
      add :labels, :map, null: false, default: %{}
      add :filenames, {:array, :text}, default: []
      add :path, :text, null: false
      add :status, :text, null: false, default: "produced"
      add :started_at, :utc_datetime
      add :ended_at, :utc_datetime
    end

    create index(:artifacts, [:item_id])
    create index(:artifacts, [:labels], using: :gin)
    create index(:artifacts, [:status])
  end
end
```

- [ ] **Step 4: Write the stage_executions migration**

```elixir
defmodule Cham.Repo.Migrations.CreateStageExecutions do
  use Ecto.Migration

  def change do
    create table(:stage_executions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :item_id, references(:items, type: :binary_id, on_delete: :delete_all), null: false
      add :stage, :text, null: false
      add :status, :text, null: false
      add :attempt, :integer, null: false, default: 1
      add :started_at, :utc_datetime
      add :ended_at, :utc_datetime
      add :duration_ms, :integer
      add :error, :text
      add :snooze_reason, :text
    end

    create index(:stage_executions, [:item_id])
  end
end
```

- [ ] **Step 5: Write the item_messages migration**

```elixir
defmodule Cham.Repo.Migrations.CreateItemMessages do
  use Ecto.Migration

  def change do
    create table(:item_messages, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :item_id, references(:items, type: :binary_id, on_delete: :delete_all), null: false
      add :role, :text, null: false
      add :content, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:item_messages, [:item_id])
  end
end
```

- [ ] **Step 6: Run migrations**

```bash
mix ecto.migrate
```

Expected: all migrations run successfully.

- [ ] **Step 7: Verify and commit**

```bash
mix test
```

Expected: all existing tests still pass (39 tests).

```bash
git add priv/repo/migrations/
git commit -m "feat: add database migrations for items, artifacts, stage_executions, item_messages

Four tables with indexes per the database-index design spec.
Items has tsvector for full-text search, GIN indexes on tags
and labels. All tables use binary_id primary keys."
```

---

## Task 2: Ecto Schemas

**Files:**
- Create: `lib/cham/items/item.ex`
- Create: `lib/cham/items/artifact.ex`
- Create: `lib/cham/items/item_message.ex`
- Create: `lib/cham/job_tracking/stage_execution.ex`

- [ ] **Step 1: Create the Item schema**

Create `lib/cham/items/item.ex`:

```elixir
defmodule Cham.Items.Item do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "items" do
    field :url, :string
    field :status, :string, default: "bootstrapping"
    field :title, :string
    field :slug, :string
    field :content_type, :string
    field :bootstrap_path, :string
    field :archive_path, :string
    field :tags, {:array, :string}, default: []
    field :error_message, :string
    field :metadata, :map, default: %{}

    has_many :artifacts, Cham.Items.Artifact
    has_many :messages, Cham.Items.ItemMessage

    timestamps(type: :utc_datetime)
  end

  @statuses ~w(bootstrapping processing complete incomplete failed)

  def create_changeset(item, attrs) do
    item
    |> cast(attrs, [:url, :tags])
    |> validate_required([:url])
    |> unique_constraint(:url)
  end

  def update_changeset(item, attrs) do
    item
    |> cast(attrs, [
      :url, :status, :title, :slug, :content_type,
      :bootstrap_path, :archive_path, :tags,
      :error_message, :metadata
    ])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:url)
    |> unique_constraint(:slug)
  end
end
```

- [ ] **Step 2: Create the Artifact schema**

Create `lib/cham/items/artifact.ex`:

```elixir
defmodule Cham.Items.Artifact do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "artifacts" do
    field :stage, :string
    field :labels, :map, default: %{}
    field :filenames, {:array, :string}, default: []
    field :path, :string
    field :status, :string, default: "produced"
    field :started_at, :utc_datetime
    field :ended_at, :utc_datetime

    belongs_to :item, Cham.Items.Item
  end

  @statuses ~w(produced failed not_applicable)

  def changeset(artifact, attrs) do
    artifact
    |> cast(attrs, [:item_id, :stage, :labels, :filenames, :path, :status, :started_at, :ended_at])
    |> validate_required([:item_id, :stage, :path])
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:item_id)
  end
end
```

- [ ] **Step 3: Create the StageExecution schema**

Create `lib/cham/job_tracking/stage_execution.ex`:

```elixir
defmodule Cham.JobTracking.StageExecution do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "stage_executions" do
    field :stage, :string
    field :status, :string
    field :attempt, :integer, default: 1
    field :started_at, :utc_datetime
    field :ended_at, :utc_datetime
    field :duration_ms, :integer
    field :error, :string
    field :snooze_reason, :string

    belongs_to :item, Cham.Items.Item
  end

  @statuses ~w(started completed failed snoozed)

  def changeset(execution, attrs) do
    execution
    |> cast(attrs, [:item_id, :stage, :status, :attempt, :started_at, :ended_at, :duration_ms, :error, :snooze_reason])
    |> validate_required([:item_id, :stage, :status])
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:item_id)
  end
end
```

- [ ] **Step 4: Create the ItemMessage schema**

Create `lib/cham/items/item_message.ex`:

```elixir
defmodule Cham.Items.ItemMessage do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "item_messages" do
    field :role, :string
    field :content, :string

    belongs_to :item, Cham.Items.Item

    timestamps(type: :utc_datetime)
  end

  @roles ~w(user assistant system)

  def changeset(message, attrs) do
    message
    |> cast(attrs, [:item_id, :role, :content])
    |> validate_required([:item_id, :role, :content])
    |> validate_inclusion(:role, @roles)
    |> foreign_key_constraint(:item_id)
  end
end
```

- [ ] **Step 5: Commit**

```bash
git add lib/cham/items/ lib/cham/job_tracking/
git commit -m "feat: add Ecto schemas for Item, Artifact, StageExecution, ItemMessage

Each schema has changesets with validation. Item has create and
update changesets. Status fields validated against allowed values."
```

---

## Task 3: Items Context

**Files:**
- Create: `lib/cham/items.ex`
- Create: `test/cham/items_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/cham/items_test.exs`:

```elixir
defmodule Cham.ItemsTest do
  use Cham.DataCase

  alias Cham.Items
  alias Cham.Items.{Item, Artifact}

  describe "create_item/1" do
    test "creates an item with valid url" do
      assert {:ok, %Item{} = item} = Items.create_item(%{url: "https://example.com/article"})
      assert item.url == "https://example.com/article"
      assert item.status == "bootstrapping"
      assert item.tags == []
    end

    test "rejects duplicate url" do
      Items.create_item(%{url: "https://example.com/dup"})
      assert {:error, changeset} = Items.create_item(%{url: "https://example.com/dup"})
      assert errors_on(changeset).url != nil
    end

    test "rejects missing url" do
      assert {:error, changeset} = Items.create_item(%{})
      assert errors_on(changeset).url != nil
    end
  end

  describe "get_item/1 and get_item!/1" do
    test "get_item returns item by id" do
      {:ok, item} = Items.create_item(%{url: "https://example.com/get"})
      assert %Item{} = Items.get_item(item.id)
    end

    test "get_item returns nil for missing id" do
      assert nil == Items.get_item(Ecto.UUID.generate())
    end

    test "get_item! raises for missing id" do
      assert_raise Ecto.NoResultsError, fn ->
        Items.get_item!(Ecto.UUID.generate())
      end
    end
  end

  describe "update_item/2" do
    test "updates item fields" do
      {:ok, item} = Items.create_item(%{url: "https://example.com/update"})

      assert {:ok, updated} =
               Items.update_item(item, %{
                 status: "processing",
                 title: "Test Article",
                 slug: "test-article-abc123",
                 archive_path: "archive/2026/04/04/test-article-abc123"
               })

      assert updated.status == "processing"
      assert updated.title == "Test Article"
      assert updated.slug == "test-article-abc123"
    end

    test "rejects invalid status" do
      {:ok, item} = Items.create_item(%{url: "https://example.com/bad-status"})
      assert {:error, changeset} = Items.update_item(item, %{status: "invalid"})
      assert errors_on(changeset).status != nil
    end
  end

  describe "delete_item/1" do
    test "deletes item and associated artifacts" do
      {:ok, item} = Items.create_item(%{url: "https://example.com/delete"})

      Items.create_artifact(%{
        item_id: item.id,
        stage: "test_stage",
        path: "processing/test-20260404T120000Z",
        labels: %{"origin" => "original"}
      })

      assert {:ok, _} = Items.delete_item(item)
      assert nil == Items.get_item(item.id)
    end
  end

  describe "list_items/1" do
    test "lists all items" do
      Items.create_item(%{url: "https://example.com/list1"})
      Items.create_item(%{url: "https://example.com/list2"})
      assert length(Items.list_items()) == 2
    end

    test "filters by status" do
      {:ok, item1} = Items.create_item(%{url: "https://example.com/filter1"})
      {:ok, _item2} = Items.create_item(%{url: "https://example.com/filter2"})
      Items.update_item(item1, %{status: "complete"})

      assert length(Items.list_items(status: "complete")) == 1
      assert length(Items.list_items(status: "bootstrapping")) == 1
    end
  end

  describe "create_artifact/1" do
    test "creates artifact for an item" do
      {:ok, item} = Items.create_item(%{url: "https://example.com/artifact"})

      assert {:ok, %Artifact{} = artifact} =
               Items.create_artifact(%{
                 item_id: item.id,
                 stage: "transcribe_whisper",
                 path: "processing/transcribe_whisper-20260404T120000Z",
                 labels: %{"origin" => "derived", "format" => "text", "type" => "transcript"},
                 filenames: ["transcript.md"],
                 status: "produced"
               })

      assert artifact.stage == "transcribe_whisper"
      assert artifact.labels["type"] == "transcript"
    end
  end

  describe "list_artifacts/1" do
    test "lists artifacts for an item" do
      {:ok, item} = Items.create_item(%{url: "https://example.com/artifacts"})

      Items.create_artifact(%{
        item_id: item.id,
        stage: "download",
        path: "processing/download-20260404T120000Z",
        labels: %{"origin" => "original"}
      })

      Items.create_artifact(%{
        item_id: item.id,
        stage: "transcribe",
        path: "processing/transcribe-20260404T120100Z",
        labels: %{"origin" => "derived"}
      })

      artifacts = Items.list_artifacts(item.id)
      assert length(artifacts) == 2
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
mix test test/cham/items_test.exs
```

Expected: compilation error — `Cham.Items` module does not exist.

- [ ] **Step 3: Implement the Items context**

Create `lib/cham/items.ex`:

```elixir
defmodule Cham.Items do
  import Ecto.Query

  alias Cham.Repo
  alias Cham.Items.{Item, Artifact}

  def create_item(attrs) do
    %Item{}
    |> Item.create_changeset(attrs)
    |> Repo.insert()
  end

  def get_item(id), do: Repo.get(Item, id)

  def get_item!(id), do: Repo.get!(Item, id)

  def update_item(%Item{} = item, attrs) do
    item
    |> Item.update_changeset(attrs)
    |> Repo.update()
  end

  def delete_item(%Item{} = item) do
    Repo.delete(item)
  end

  def list_items(filters \\ []) do
    Item
    |> apply_filters(filters)
    |> Repo.all()
  end

  defp apply_filters(query, []), do: query

  defp apply_filters(query, [{:status, status} | rest]) do
    query
    |> where([i], i.status == ^status)
    |> apply_filters(rest)
  end

  defp apply_filters(query, [_ | rest]), do: apply_filters(query, rest)

  def create_artifact(attrs) do
    %Artifact{}
    |> Artifact.changeset(attrs)
    |> Repo.insert()
  end

  def list_artifacts(item_id) do
    Artifact
    |> where([a], a.item_id == ^item_id)
    |> Repo.all()
  end
end
```

- [ ] **Step 4: Create the DataCase test helper**

Phoenix should have generated `test/support/data_case.ex`, but verify it exists and sets up the sandbox. If it doesn't exist, create it:

```elixir
defmodule Cham.DataCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      alias Cham.Repo
      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Cham.DataCase
    end
  end

  setup tags do
    Cham.DataCase.setup_sandbox(tags)
    :ok
  end

  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Cham.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end

  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
mix test test/cham/items_test.exs
```

Expected: all 10 tests pass.

- [ ] **Step 6: Run all tests**

```bash
mix test
```

Expected: all tests pass (39 existing + 10 new = 49).

- [ ] **Step 7: Commit**

```bash
git add lib/cham/items.ex lib/cham/items/ lib/cham/job_tracking/ test/cham/items_test.exs
git commit -m "feat: add Items context with CRUD for items and artifacts

Context module with create, read, update, delete for items.
Artifact creation and listing per item. Status filtering on
list_items. Changesets validate statuses and required fields."
```

---

## Task 4: Filesystem Manager

Pure filesystem operations with no knowledge of archive layout or artifact semantics.

**Files:**
- Create: `lib/cham/archive/filesystem_manager.ex`
- Create: `test/cham/archive/filesystem_manager_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/cham/archive/filesystem_manager_test.exs`:

```elixir
defmodule Cham.Archive.FilesystemManagerTest do
  use ExUnit.Case, async: true

  alias Cham.Archive.FilesystemManager

  setup do
    tmp = Path.join(System.tmp_dir!(), "cham_fs_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    %{tmp: tmp}
  end

  describe "mkdir_p/1" do
    test "creates nested directories", %{tmp: tmp} do
      path = Path.join([tmp, "a", "b", "c"])
      assert :ok = FilesystemManager.mkdir_p(path)
      assert File.dir?(path)
    end

    test "succeeds if directory already exists", %{tmp: tmp} do
      assert :ok = FilesystemManager.mkdir_p(tmp)
    end
  end

  describe "atomic_write/2" do
    test "writes file content atomically", %{tmp: tmp} do
      path = Path.join(tmp, "test.txt")
      assert :ok = FilesystemManager.atomic_write(path, "hello world")
      assert File.read!(path) == "hello world"
    end

    test "creates parent directories if needed", %{tmp: tmp} do
      path = Path.join([tmp, "sub", "dir", "test.txt"])
      assert :ok = FilesystemManager.atomic_write(path, "content")
      assert File.read!(path) == "content"
    end

    test "no temp file left behind on success", %{tmp: tmp} do
      path = Path.join(tmp, "clean.txt")
      FilesystemManager.atomic_write(path, "data")
      files = File.ls!(tmp)
      assert files == ["clean.txt"]
    end
  end

  describe "move/2" do
    test "moves a file", %{tmp: tmp} do
      src = Path.join(tmp, "src.txt")
      dst = Path.join(tmp, "dst.txt")
      File.write!(src, "data")

      assert :ok = FilesystemManager.move(src, dst)
      refute File.exists?(src)
      assert File.read!(dst) == "data"
    end

    test "moves a directory tree", %{tmp: tmp} do
      src = Path.join(tmp, "src_dir")
      dst = Path.join(tmp, "dst_dir")
      File.mkdir_p!(Path.join(src, "sub"))
      File.write!(Path.join([src, "sub", "file.txt"]), "nested")

      assert :ok = FilesystemManager.move(src, dst)
      refute File.exists?(src)
      assert File.read!(Path.join([dst, "sub", "file.txt"])) == "nested"
    end

    test "creates parent directories for destination", %{tmp: tmp} do
      src = Path.join(tmp, "src.txt")
      dst = Path.join([tmp, "new", "path", "dst.txt"])
      File.write!(src, "data")

      assert :ok = FilesystemManager.move(src, dst)
      assert File.read!(dst) == "data"
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
mix test test/cham/archive/filesystem_manager_test.exs
```

Expected: compilation error — module does not exist.

- [ ] **Step 3: Implement Filesystem Manager**

Create `lib/cham/archive/filesystem_manager.ex`:

```elixir
defmodule Cham.Archive.FilesystemManager do
  @doc """
  Create directories recursively.
  """
  def mkdir_p(path) do
    File.mkdir_p(path)
  end

  @doc """
  Write content to a file atomically: write to a temp file in the same
  directory, then rename. The file is either complete or absent, never
  half-written. Creates parent directories if needed.
  """
  def atomic_write(path, content) do
    dir = Path.dirname(path)
    File.mkdir_p!(dir)
    tmp_path = path <> ".tmp.#{:erlang.unique_integer([:positive])}"

    with :ok <- File.write(tmp_path, content) do
      File.rename(tmp_path, path)
    end
  end

  @doc """
  Move a file or directory from src to dst. Creates parent directories
  for the destination. Falls back to copy+delete if rename fails
  (cross-device move).
  """
  def move(src, dst) do
    File.mkdir_p!(Path.dirname(dst))

    case File.rename(src, dst) do
      :ok ->
        :ok

      {:error, :exdev} ->
        # Cross-device: copy then delete
        if File.dir?(src) do
          File.cp_r!(src, dst)
          File.rm_rf!(src)
        else
          File.cp!(src, dst)
          File.rm!(src)
        end

        :ok
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
mix test test/cham/archive/filesystem_manager_test.exs
```

Expected: all 8 tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/cham/archive/filesystem_manager.ex test/cham/archive/filesystem_manager_test.exs
git commit -m "feat: add Filesystem Manager for atomic writes and safe moves

Generic filesystem operations: mkdir_p, atomic_write (tmp+rename),
and move with cross-device fallback. No knowledge of archive layout."
```

---

## Task 5: Archive Manager

Archive-aware filesystem operations. Encodes the archive directory layout (`archive/YYYY/MM/DD/<slug>/processing/<plugin_id>-<timestamp>/`). Uses Filesystem Manager for actual FS operations.

**Files:**
- Create: `lib/cham/archive/archive_manager.ex`
- Create: `test/cham/archive/archive_manager_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/cham/archive/archive_manager_test.exs`:

```elixir
defmodule Cham.Archive.ArchiveManagerTest do
  use ExUnit.Case, async: true

  alias Cham.Archive.ArchiveManager

  setup do
    root = Path.join(System.tmp_dir!(), "cham_archive_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  describe "item_path/3" do
    test "returns date-sharded archive path", %{root: root} do
      date = ~D[2026-04-02]
      path = ArchiveManager.item_path(root, "some-video-abc123", date)
      assert path == Path.join(root, "archive/2026/04/02/some-video-abc123")
    end
  end

  describe "bootstrap_path/2" do
    test "returns bootstrap staging path", %{root: root} do
      item_id = "550e8400-e29b-41d4-a716-446655440000"
      path = ArchiveManager.bootstrap_path(root, item_id)
      assert path == Path.join(root, "tmp/bootstrap/550e8400-e29b-41d4-a716-446655440000")
    end
  end

  describe "create_stage_dir/3" do
    test "creates a timestamped processing directory", %{root: root} do
      item_dir = Path.join(root, "test_item")
      File.mkdir_p!(item_dir)

      {:ok, stage_dir} = ArchiveManager.create_stage_dir(item_dir, "transcribe_whisper")

      assert File.dir?(stage_dir)
      assert stage_dir =~ ~r"processing/transcribe_whisper-\d{8}T\d{6}Z$"
    end

    test "two calls produce different directories", %{root: root} do
      item_dir = Path.join(root, "test_item2")
      File.mkdir_p!(item_dir)

      {:ok, dir1} = ArchiveManager.create_stage_dir(item_dir, "stage_a")
      Process.sleep(1100)
      {:ok, dir2} = ArchiveManager.create_stage_dir(item_dir, "stage_a")

      assert dir1 != dir2
    end
  end

  describe "move_to_archive/4" do
    test "moves bootstrap dir to archive location", %{root: root} do
      # Set up a bootstrap directory with content
      item_id = "test-item-id"
      bootstrap = ArchiveManager.bootstrap_path(root, item_id)
      File.mkdir_p!(Path.join(bootstrap, "processing/input-20260402T143000Z"))
      File.write!(Path.join(bootstrap, "processing/input-20260402T143000Z/artifact.json"), "{}")

      slug = "test-article-abc123"
      date = ~D[2026-04-02]

      assert {:ok, archive_path} = ArchiveManager.move_to_archive(root, bootstrap, slug, date)

      expected = Path.join(root, "archive/2026/04/02/test-article-abc123")
      assert archive_path == expected
      assert File.exists?(Path.join(archive_path, "processing/input-20260402T143000Z/artifact.json"))
      refute File.exists?(bootstrap)
    end
  end

  describe "list_items/1" do
    test "lists item directories in the archive", %{root: root} do
      # Create some archive items
      archive = Path.join(root, "archive")
      File.mkdir_p!(Path.join(archive, "2026/04/02/video-abc/processing"))
      File.mkdir_p!(Path.join(archive, "2026/04/03/article-def/processing"))

      items = ArchiveManager.list_items(root)
      slugs = Enum.map(items, & &1.slug)
      assert "video-abc" in slugs
      assert "article-def" in slugs
      assert length(items) == 2
    end

    test "returns empty list for empty archive", %{root: root} do
      assert ArchiveManager.list_items(root) == []
    end
  end

  describe "list_stage_dirs/1" do
    test "lists processing directories for an item", %{root: root} do
      item_dir = Path.join(root, "test_item")
      proc = Path.join(item_dir, "processing")
      File.mkdir_p!(Path.join(proc, "input-20260402T143000Z"))
      File.mkdir_p!(Path.join(proc, "transcribe_whisper-20260402T144012Z"))

      dirs = ArchiveManager.list_stage_dirs(item_dir)
      assert length(dirs) == 2
      assert Enum.any?(dirs, &String.contains?(&1, "input-"))
      assert Enum.any?(dirs, &String.contains?(&1, "transcribe_whisper-"))
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
mix test test/cham/archive/archive_manager_test.exs
```

Expected: compilation error — module does not exist.

- [ ] **Step 3: Implement Archive Manager**

Create `lib/cham/archive/archive_manager.ex`:

```elixir
defmodule Cham.Archive.ArchiveManager do
  alias Cham.Archive.FilesystemManager

  @doc """
  Return the archive path for an item: <root>/archive/YYYY/MM/DD/<slug>
  """
  def item_path(root, slug, %Date{} = date) do
    year = date.year |> Integer.to_string()
    month = date.month |> Integer.to_string() |> String.pad_leading(2, "0")
    day = date.day |> Integer.to_string() |> String.pad_leading(2, "0")
    Path.join([root, "archive", year, month, day, slug])
  end

  @doc """
  Return the bootstrap staging path: <root>/tmp/bootstrap/<item_id>
  """
  def bootstrap_path(root, item_id) do
    Path.join([root, "tmp", "bootstrap", item_id])
  end

  @doc """
  Create a timestamped processing directory: <item_dir>/processing/<plugin_id>-<ISO8601>
  Returns {:ok, full_path}.
  """
  def create_stage_dir(item_dir, plugin_id) do
    timestamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")
    dir_name = "#{plugin_id}-#{timestamp}"
    full_path = Path.join([item_dir, "processing", dir_name])
    FilesystemManager.mkdir_p(full_path)
    {:ok, full_path}
  end

  @doc """
  Move an item from bootstrap staging to its permanent archive location.
  Returns {:ok, archive_path}.
  """
  def move_to_archive(root, bootstrap_path, slug, %Date{} = date) do
    archive_path = item_path(root, slug, date)
    FilesystemManager.mkdir_p(Path.dirname(archive_path))
    :ok = FilesystemManager.move(bootstrap_path, archive_path)
    {:ok, archive_path}
  end

  @doc """
  List all items in the archive. Returns a list of maps with :slug and :path.
  """
  def list_items(root) do
    archive_dir = Path.join(root, "archive")

    if File.dir?(archive_dir) do
      archive_dir
      |> walk_item_dirs()
      |> Enum.map(fn path ->
        %{slug: Path.basename(path), path: path}
      end)
    else
      []
    end
  end

  @doc """
  List all processing stage directories for an item.
  Returns list of full paths, sorted alphabetically.
  """
  def list_stage_dirs(item_dir) do
    proc_dir = Path.join(item_dir, "processing")

    if File.dir?(proc_dir) do
      proc_dir
      |> File.ls!()
      |> Enum.sort()
      |> Enum.map(&Path.join(proc_dir, &1))
      |> Enum.filter(&File.dir?/1)
    else
      []
    end
  end

  # Walk archive/YYYY/MM/DD/*/ to find item directories
  defp walk_item_dirs(archive_dir) do
    archive_dir
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.filter(fn path ->
      File.dir?(path) and File.dir?(Path.join(path, "processing"))
    end)
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
mix test test/cham/archive/archive_manager_test.exs
```

Expected: all 7 tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/cham/archive/archive_manager.ex test/cham/archive/archive_manager_test.exs
git commit -m "feat: add Archive Manager for archive-aware path resolution

Encodes archive layout: archive/YYYY/MM/DD/<slug>/processing/<stage>-<ts>.
Handles bootstrap staging, move-to-archive, item listing, and
stage directory creation. Built on Filesystem Manager."
```

---

## Task 6: Metadata Manager

Reads and merges `artifact.json` files across stage processing directories. Provides metadata query helpers.

**Files:**
- Create: `lib/cham/archive/metadata_manager.ex`
- Create: `test/cham/archive/metadata_manager_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/cham/archive/metadata_manager_test.exs`:

```elixir
defmodule Cham.Archive.MetadataManagerTest do
  use ExUnit.Case, async: true

  alias Cham.Archive.MetadataManager

  setup do
    root = Path.join(System.tmp_dir!(), "cham_meta_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  defp write_artifact_json(item_dir, stage_dir_name, data) do
    dir = Path.join([item_dir, "processing", stage_dir_name])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "artifact.json"), Jason.encode!(data))
    dir
  end

  describe "read_artifact_json/1" do
    test "parses a valid artifact.json file", %{root: root} do
      dir = write_artifact_json(root, "input-20260402T143000Z", %{
        "stage" => %{"plugin_id" => "input", "start_ts" => 1_743_609_000, "end_ts" => 1_743_609_001},
        "artifacts" => [%{"labels" => %{"domain" => "example.com"}, "filenames" => []}],
        "item_metadata" => %{"url" => "https://example.com"}
      })

      assert {:ok, data} = MetadataManager.read_artifact_json(dir)
      assert data["stage"]["plugin_id"] == "input"
      assert length(data["artifacts"]) == 1
    end

    test "returns error for missing file", %{root: root} do
      assert {:error, :not_found} = MetadataManager.read_artifact_json(Path.join(root, "nonexistent"))
    end

    test "returns error for invalid JSON", %{root: root} do
      dir = Path.join([root, "processing", "bad-20260402T143000Z"])
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "artifact.json"), "not json{{{")
      assert {:error, _} = MetadataManager.read_artifact_json(dir)
    end
  end

  describe "merge_item_state/1" do
    test "merges artifacts from multiple stages with latest-timestamp-wins", %{root: root} do
      write_artifact_json(root, "input-20260402T143000Z", %{
        "stage" => %{"plugin_id" => "input", "start_ts" => 1_743_609_000, "end_ts" => 1_743_609_001},
        "artifacts" => [%{"labels" => %{"domain" => "example.com"}, "filenames" => []}],
        "item_metadata" => %{"url" => "https://example.com", "title" => "Original Title"}
      })

      write_artifact_json(root, "download-20260402T143005Z", %{
        "stage" => %{"plugin_id" => "download", "start_ts" => 1_743_609_005, "end_ts" => 1_743_609_060},
        "artifacts" => [%{"labels" => %{"origin" => "original", "format" => "text"}, "filenames" => ["content.html"]}],
        "item_metadata" => %{"title" => "Downloaded Title", "content_type" => "article"}
      })

      assert {:ok, state} = MetadataManager.merge_item_state(root)
      assert length(state.artifacts) == 2
      # Latest timestamp wins for metadata
      assert state.metadata["title"] == "Downloaded Title"
      assert state.metadata["url"] == "https://example.com"
      assert state.metadata["content_type"] == "article"
    end

    test "returns empty state for item with no processing dirs", %{root: root} do
      assert {:ok, state} = MetadataManager.merge_item_state(root)
      assert state.artifacts == []
      assert state.metadata == %{}
    end
  end

  describe "get_latest/2" do
    test "returns most recent metadata value", %{root: root} do
      write_artifact_json(root, "input-20260402T143000Z", %{
        "stage" => %{"plugin_id" => "input", "start_ts" => 1_743_609_000, "end_ts" => 1_743_609_001},
        "artifacts" => [],
        "item_metadata" => %{"title" => "First"}
      })

      write_artifact_json(root, "clean_title-20260402T144000Z", %{
        "stage" => %{"plugin_id" => "clean_title", "start_ts" => 1_743_609_600, "end_ts" => 1_743_609_601},
        "artifacts" => [],
        "item_metadata" => %{"title" => "Cleaned"}
      })

      assert MetadataManager.get_latest(root, "title") == "Cleaned"
    end

    test "returns nil for missing key", %{root: root} do
      assert MetadataManager.get_latest(root, "nonexistent") == nil
    end
  end

  describe "get_all/2" do
    test "returns all values for a key across stages", %{root: root} do
      write_artifact_json(root, "input-20260402T143000Z", %{
        "stage" => %{"plugin_id" => "input", "start_ts" => 1_743_609_000, "end_ts" => 1_743_609_001},
        "artifacts" => [],
        "item_metadata" => %{"title" => "Input Title"}
      })

      write_artifact_json(root, "clean_title-20260402T144000Z", %{
        "stage" => %{"plugin_id" => "clean_title", "start_ts" => 1_743_609_600, "end_ts" => 1_743_609_601},
        "artifacts" => [],
        "item_metadata" => %{"title" => "Clean Title"}
      })

      result = MetadataManager.get_all(root, "title")
      assert result["input"] == "Input Title"
      assert result["clean_title"] == "Clean Title"
    end
  end

  describe "get_from/3" do
    test "returns value from a specific stage", %{root: root} do
      write_artifact_json(root, "download-20260402T143005Z", %{
        "stage" => %{"plugin_id" => "download", "start_ts" => 1_743_609_005, "end_ts" => 1_743_609_060},
        "artifacts" => [],
        "item_metadata" => %{"content_type" => "article"}
      })

      assert MetadataManager.get_from(root, "download", "content_type") == "article"
    end

    test "returns nil for missing stage", %{root: root} do
      assert MetadataManager.get_from(root, "nonexistent", "title") == nil
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
mix test test/cham/archive/metadata_manager_test.exs
```

Expected: compilation error — module does not exist.

- [ ] **Step 3: Implement Metadata Manager**

Create `lib/cham/archive/metadata_manager.ex`:

```elixir
defmodule Cham.Archive.MetadataManager do
  alias Cham.Archive.ArchiveManager

  @doc """
  Read and parse artifact.json from a stage processing directory.
  """
  def read_artifact_json(stage_dir) do
    path = Path.join(stage_dir, "artifact.json")

    if File.exists?(path) do
      case File.read!(path) |> Jason.decode() do
        {:ok, data} -> {:ok, data}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :not_found}
    end
  end

  @doc """
  Scan all processing/*/artifact.json for an item directory and merge
  into a single state using latest-timestamp-wins for metadata.
  Returns {:ok, %{artifacts: [...], metadata: %{...}, stages: [...]}}
  """
  def merge_item_state(item_dir) do
    stage_dirs = ArchiveManager.list_stage_dirs(item_dir)

    stage_data =
      stage_dirs
      |> Enum.map(fn dir -> {dir, read_artifact_json(dir)} end)
      |> Enum.filter(fn {_dir, result} -> match?({:ok, _}, result) end)
      |> Enum.map(fn {dir, {:ok, data}} -> {dir, data} end)
      |> Enum.sort_by(fn {_dir, data} ->
        get_in(data, ["stage", "end_ts"]) || 0
      end)

    artifacts =
      Enum.flat_map(stage_data, fn {dir, data} ->
        (data["artifacts"] || [])
        |> Enum.map(fn artifact ->
          Map.put(artifact, "stage_dir", Path.basename(dir))
        end)
      end)

    # Latest-timestamp-wins for metadata
    metadata =
      Enum.reduce(stage_data, %{}, fn {_dir, data}, acc ->
        case data["item_metadata"] do
          nil -> acc
          meta -> Map.merge(acc, meta)
        end
      end)

    stages =
      Enum.map(stage_data, fn {dir, data} ->
        %{
          "dir" => Path.basename(dir),
          "plugin_id" => get_in(data, ["stage", "plugin_id"]),
          "start_ts" => get_in(data, ["stage", "start_ts"]),
          "end_ts" => get_in(data, ["stage", "end_ts"])
        }
      end)

    {:ok, %{artifacts: artifacts, metadata: metadata, stages: stages}}
  end

  @doc """
  Get the most recent value for a metadata key (latest end_ts wins).
  """
  def get_latest(item_dir, key) do
    {:ok, state} = merge_item_state(item_dir)
    Map.get(state.metadata, key)
  end

  @doc """
  Get all values for a metadata key across stages.
  Returns %{plugin_id => value} ordered by end_ts.
  """
  def get_all(item_dir, key) do
    stage_dirs = ArchiveManager.list_stage_dirs(item_dir)

    stage_dirs
    |> Enum.map(fn dir -> {dir, read_artifact_json(dir)} end)
    |> Enum.filter(fn {_dir, result} -> match?({:ok, _}, result) end)
    |> Enum.map(fn {dir, {:ok, data}} -> {dir, data} end)
    |> Enum.sort_by(fn {_dir, data} -> get_in(data, ["stage", "end_ts"]) || 0 end)
    |> Enum.reduce(%{}, fn {_dir, data}, acc ->
      plugin_id = get_in(data, ["stage", "plugin_id"])
      meta = data["item_metadata"] || %{}

      case Map.get(meta, key) do
        nil -> acc
        value -> Map.put(acc, plugin_id, value)
      end
    end)
  end

  @doc """
  Get a specific metadata key from a specific stage's artifact.json.
  """
  def get_from(item_dir, stage_id, key) do
    stage_dirs = ArchiveManager.list_stage_dirs(item_dir)

    stage_dirs
    |> Enum.find(fn dir ->
      case read_artifact_json(dir) do
        {:ok, data} -> get_in(data, ["stage", "plugin_id"]) == stage_id
        _ -> false
      end
    end)
    |> case do
      nil ->
        nil

      dir ->
        {:ok, data} = read_artifact_json(dir)
        get_in(data, ["item_metadata", key])
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
mix test test/cham/archive/metadata_manager_test.exs
```

Expected: all 8 tests pass.

- [ ] **Step 5: Run all tests**

```bash
mix test
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add lib/cham/archive/metadata_manager.ex test/cham/archive/metadata_manager_test.exs
git commit -m "feat: add Metadata Manager for artifact.json parsing and merging

Reads artifact.json files from stage processing directories.
Merges across stages with latest-timestamp-wins for item metadata.
Provides get_latest, get_all, get_from query helpers."
```

---

## Verification

After all tasks, run:

```bash
mix format --check-formatted
mix test
```

All should pass with zero warnings.
