defmodule Cham.Archive.Component do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "components" do
    field :content_type, :string

    belongs_to :snapshot, Cham.Archive.Snapshot
    has_many :artifacts, Cham.Archive.Artifact

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(component, attrs) do
    component
    |> cast(attrs, [:snapshot_id, :content_type])
    |> validate_required([:snapshot_id, :content_type])
    |> unique_constraint([:snapshot_id, :content_type],
      name: :components_snapshot_id_content_type_index
    )
    |> foreign_key_constraint(:snapshot_id)
  end
end
