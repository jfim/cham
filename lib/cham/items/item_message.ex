defmodule Cham.Items.ItemMessage do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "item_messages" do
    field :role, :string
    field :content, :string

    belongs_to :item, Cham.Items.Item

    timestamps(type: :utc_datetime)
  end

  @roles ~w(user assistant system)

  def changeset(message, attrs) do
    message
    |> cast(attrs, [:item_id, :role, :content])
    |> validate_required([:item_id, :role, :content])
    |> validate_inclusion(:role, @roles)
    |> foreign_key_constraint(:item_id)
  end
end
