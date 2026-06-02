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

    field :item_id, :binary_id
  end

  @statuses ~w(started completed failed snoozed crashed)

  def changeset(execution, attrs) do
    execution
    |> cast(attrs, [
      :item_id,
      :stage,
      :status,
      :attempt,
      :started_at,
      :ended_at,
      :duration_ms,
      :error,
      :snooze_reason
    ])
    |> validate_required([:item_id, :stage, :status])
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:item_id)
  end
end
