defmodule Cham.Archive.UrlIdentity do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  @roles ~w(submitted redirect_alias)

  schema "url_identities" do
    field :url_hash, :string
    field :normalized_url, :string
    field :role, :string

    belongs_to :item, Cham.Archive.Item

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(identity, attrs) do
    identity
    |> cast(attrs, [:item_id, :url_hash, :normalized_url, :role])
    |> validate_required([:item_id, :url_hash, :normalized_url, :role])
    |> validate_inclusion(:role, @roles)
    |> unique_constraint(:url_hash)
    |> foreign_key_constraint(:item_id)
  end
end
