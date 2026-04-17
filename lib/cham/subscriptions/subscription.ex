defmodule Cham.Subscriptions.Subscription do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "subscriptions" do
    field :source_url, :string
    field :backend, :string
    field :title, :string
    field :poll_interval_seconds, :integer, default: 86_400
    field :last_polled_at, :utc_datetime_usec
    field :last_error, :string
    field :consecutive_failures, :integer, default: 0
    field :active, :boolean, default: true
    field :backend_config, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  @fields ~w(source_url backend title poll_interval_seconds last_polled_at
             last_error consecutive_failures active backend_config)a

  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, @fields)
    |> validate_required([:source_url, :backend, :title, :poll_interval_seconds])
    |> validate_inclusion(:poll_interval_seconds, [3600, 21_600, 86_400])
    |> unique_constraint(:source_url)
  end

  def update_changeset(subscription, attrs) do
    subscription
    |> cast(attrs, @fields)
    |> validate_inclusion(:poll_interval_seconds, [3600, 21_600, 86_400])
    |> unique_constraint(:source_url)
  end
end
