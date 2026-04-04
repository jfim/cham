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
