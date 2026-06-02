defmodule Cham.Archive.Edge do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  @edge_types ~w(embed linked mirror)
  @provenances ~w(extractor user)

  schema "edges" do
    field :edge_type, :string
    field :target_url_hash, :string
    field :provenance, :string

    belongs_to :source_item, Cham.Archive.Item
    belongs_to :target_item, Cham.Archive.Item

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(edge, attrs) do
    edge
    |> cast(attrs, [:source_item_id, :edge_type, :target_url_hash, :target_item_id, :provenance])
    |> validate_required([:source_item_id, :edge_type, :target_url_hash, :provenance])
    |> validate_inclusion(:edge_type, @edge_types)
    |> validate_inclusion(:provenance, @provenances)
    |> foreign_key_constraint(:source_item_id)
    |> foreign_key_constraint(:target_item_id)
  end
end
