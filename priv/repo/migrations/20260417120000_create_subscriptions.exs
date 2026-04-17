defmodule Cham.Repo.Migrations.CreateSubscriptions do
  use Ecto.Migration

  def change do
    create table(:subscriptions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :source_url, :string, null: false
      add :backend, :string, null: false
      add :title, :string
      add :poll_interval_seconds, :integer, null: false, default: 86_400
      add :last_polled_at, :utc_datetime_usec
      add :last_error, :text
      add :consecutive_failures, :integer, null: false, default: 0
      add :active, :boolean, null: false, default: true
      add :backend_config, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create unique_index(:subscriptions, [:source_url])
    create index(:subscriptions, [:active, :last_polled_at])

    alter table(:items) do
      add :subscription_id, references(:subscriptions, type: :binary_id, on_delete: :nilify_all)
      add :source_item_id, :string
    end

    create unique_index(:items, [:subscription_id, :source_item_id],
             where: "subscription_id IS NOT NULL",
             name: :items_subscription_source_item_id_index
           )
  end
end
