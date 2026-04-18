defmodule Cham.Items.Item do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "items" do
    field :url, :string
    field :status, :string, default: "bootstrapping"
    field :title, :string
    field :slug, :string
    field :content_type, :string
    field :bootstrap_path, :string
    field :archive_path, :string
    field :tags, {:array, :string}, default: []
    field :error_message, :string
    field :metadata, :map, default: %{}
    field :subscription_id, :binary_id
    field :source_item_id, :string

    has_many :artifacts, Cham.Items.Artifact
    has_many :messages, Cham.Items.ItemMessage

    timestamps(type: :utc_datetime)
  end

  @statuses ~w(bootstrapping processing complete incomplete failed cancelled)

  def create_changeset(item, attrs) do
    item
    |> cast(attrs, [
      :url,
      :tags,
      :title,
      :content_type,
      :status,
      :slug,
      :metadata,
      :subscription_id,
      :source_item_id
    ])
    |> validate_required([:url])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:url)
    |> unique_constraint(:slug)
    |> unique_constraint([:subscription_id, :source_item_id],
      name: :items_subscription_source_item_id_index
    )
  end

  def update_changeset(item, attrs) do
    item
    |> cast(attrs, [
      :url,
      :status,
      :title,
      :slug,
      :content_type,
      :bootstrap_path,
      :archive_path,
      :tags,
      :error_message,
      :metadata,
      :subscription_id,
      :source_item_id
    ])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:url)
    |> unique_constraint(:slug)
  end
end
