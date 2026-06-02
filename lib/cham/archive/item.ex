defmodule Cham.Archive.Item do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  @statuses ~w(bootstrapping extracting processing complete incomplete failed)

  schema "items" do
    field :slug, :string
    field :title, :string
    field :status, :string, default: "bootstrapping"
    field :archive_path, :string
    field :first_captured_at, :utc_datetime
    field :tags, {:array, :string}, default: []
    field :metadata, :map, default: %{}

    has_many :url_identities, Cham.Archive.UrlIdentity
    has_many :snapshots, Cham.Archive.Snapshot

    timestamps(type: :utc_datetime)
  end

  def create_changeset(item, attrs) do
    item
    |> cast(attrs, [:slug, :title, :status, :archive_path, :first_captured_at, :tags, :metadata])
    |> validate_required([:slug, :archive_path, :first_captured_at])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:archive_path)
  end

  def update_changeset(item, attrs) do
    item
    |> cast(attrs, [:slug, :title, :status, :archive_path, :tags, :metadata])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:archive_path)
  end
end
