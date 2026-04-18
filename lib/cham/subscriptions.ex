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

  @doc """
  Subscribe to a feed item's source URL. Looks up the feed_metadata artifact
  on the item, reads the subscription_backend and title, then creates a
  subscription and enqueues an immediate poll honoring the chosen backfill mode.

  `attrs` can include:
    - `:title` (overrides the feed title)
    - `:poll_interval_seconds`
    - `:backfill` — :none | {:last_n, n} | {:since, %DateTime{}}
  """
  def subscribe_from_item(item_id, attrs \\ %{}) do
    item = Cham.Items.get_item!(item_id)

    with {:ok, metadata} <- read_feed_metadata(item),
         backend_id when is_binary(backend_id) <- metadata["subscription_backend"],
         feed_title when is_binary(feed_title) <- metadata["title"] do
      poll_interval = Map.get(attrs, :poll_interval_seconds, 86_400)
      user_title = Map.get(attrs, :title) || feed_title

      params = %{
        source_url: item.url,
        backend: backend_id,
        title: user_title,
        poll_interval_seconds: poll_interval
      }

      with {:ok, sub} <- create_subscription(params) do
        enqueue_initial_poll(sub, Map.get(attrs, :backfill, :none))
        {:ok, sub}
      end
    else
      nil -> {:error, :no_feed_metadata}
      :error -> {:error, :no_feed_metadata}
      {:error, _} = err -> err
    end
  end

  defp read_feed_metadata(item) do
    artifacts = Cham.Items.list_artifacts(item.id)

    feed_artifact =
      Enum.find(artifacts, fn a ->
        labels = a.labels || %{}
        labels["origin"] == "derived" and labels["type"] == "feed_metadata"
      end)

    case feed_artifact do
      nil ->
        :error

      artifact ->
        case Cham.Items.read_artifact_content(item, artifact) do
          {:ok, content} ->
            case Jason.decode(content) do
              {:ok, decoded} -> {:ok, decoded}
              _ -> :error
            end

          _ ->
            :error
        end
    end
  end

  defp enqueue_initial_poll(sub, backfill) do
    %{"subscription_id" => sub.id, "backfill" => encode_backfill(backfill)}
    |> Cham.Subscriptions.PollWorker.new()
    |> Oban.insert()
  end

  @doc """
  Enqueue an immediate poll for an existing subscription (no backfill).
  """
  def enqueue_poll(%Subscription{} = sub) do
    %{"subscription_id" => sub.id, "backfill" => "incremental"}
    |> Cham.Subscriptions.PollWorker.new()
    |> Oban.insert()
  end

  defp encode_backfill(:none), do: "none"
  defp encode_backfill(nil), do: "none"
  defp encode_backfill({:last_n, n}), do: %{"mode" => "last_n", "n" => n}

  defp encode_backfill({:since, %DateTime{} = dt}),
    do: %{"mode" => "since", "date" => DateTime.to_iso8601(dt)}
end
