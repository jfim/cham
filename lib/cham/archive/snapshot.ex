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
