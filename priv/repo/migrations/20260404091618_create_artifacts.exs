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
