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
