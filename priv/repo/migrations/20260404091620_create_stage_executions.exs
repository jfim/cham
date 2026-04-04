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
