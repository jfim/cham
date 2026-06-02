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
    #
    # The preserved tables (stage_executions / item_messages) keep their schema, but
    # any pre-existing ROWS reference the dropped v2 items and are now orphaned (the
    # recreated items table is empty). Per the Phase 0a teardown intent (fresh v3 start;
    # the filesystem archive is the source of truth and Postgres is a rebuildable index),
    # this stale v2 ingestion data is discarded so the FK can be re-established. Without
    # this delete, ADD CONSTRAINT fails with a foreign_key_violation on dev DBs that
    # still hold v2 rows.
    execute """
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_name = 'stage_executions' AND column_name = 'item_id') THEN
        DELETE FROM stage_executions;
        ALTER TABLE stage_executions
          ADD CONSTRAINT stage_executions_item_id_fkey
          FOREIGN KEY (item_id) REFERENCES items(id) ON DELETE CASCADE;
      END IF;
      IF EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_name = 'item_messages' AND column_name = 'item_id') THEN
        DELETE FROM item_messages;
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
