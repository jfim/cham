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
