defmodule Cham.Archive.Artifact do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  @categories ~w(capture extracted derived)
  @statuses ~w(produced failed not_applicable)

  schema "artifacts" do
    field :category, :string
    field :stage, :string
    field :labels, :map, default: %{}
    field :filenames, {:array, :string}, default: []
    field :path, :string
    field :status, :string, default: "produced"
    field :version, :integer
    field :started_at, :utc_datetime
    field :ended_at, :utc_datetime

    belongs_to :snapshot, Cham.Archive.Snapshot
    belongs_to :component, Cham.Archive.Component
  end

  def changeset(artifact, attrs) do
    artifact
    |> cast(attrs, [
      :snapshot_id,
      :component_id,
      :category,
      :stage,
      :labels,
      :filenames,
      :path,
      :status,
      :version,
      :started_at,
      :ended_at
    ])
    |> validate_required([:snapshot_id, :category, :stage, :path])
    |> validate_inclusion(:category, @categories)
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:snapshot_id)
    |> foreign_key_constraint(:component_id)
  end
end
