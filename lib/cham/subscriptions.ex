defmodule Cham.Subscriptions do
  @moduledoc """
  Context for subscription CRUD, polling scheduling queries, and the
  already-subscribed lookup performed at ingest time.
  """

  import Ecto.Query, warn: false
  alias Cham.Repo
  alias Cham.Subscriptions.Subscription

  def create_subscription(attrs) do
    attrs |> Subscription.create_changeset() |> Repo.insert()
  end

  def update_subscription(%Subscription{} = sub, attrs) do
    sub |> Subscription.update_changeset(attrs) |> Repo.update()
  end

  def delete_subscription(%Subscription{} = sub), do: Repo.delete(sub)

  def get_subscription!(id), do: Repo.get!(Subscription, id)

  def get_by_source_url(url) when is_binary(url) do
    Repo.get_by(Subscription, source_url: url)
  end

  def list_subscriptions do
    Repo.all(from s in Subscription, order_by: [desc: s.inserted_at])
  end

  def list_due(now \\ DateTime.utc_now()) do
    Repo.all(
      from s in Subscription,
        where: s.active == true,
        where:
          is_nil(s.last_polled_at) or
            fragment(
              "? + make_interval(secs => ?) <= ?",
              s.last_polled_at,
              s.poll_interval_seconds,
              ^now
            )
    )
  end
end
