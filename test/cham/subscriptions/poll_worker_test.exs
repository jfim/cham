defmodule Cham.Subscriptions.PollWorkerTest do
  use Cham.DataCase, async: false
  use Oban.Testing, repo: Cham.Repo

  import Ecto.Query

  alias Cham.Repo
  alias Cham.Subscriptions
  alias Cham.Subscriptions.{BackendRegistry, PollWorker}
  alias Cham.Items
  alias Cham.Items.Item

  defmodule MockBackend do
    @behaviour Cham.Subscriptions.Backend
    def id, do: :mock
    def name, do: "Mock"
    def stream_pages(_url) do
      [[
        %{source_item_id: "b", url: "https://mock/b", title: "B", timestamp: ~U[2026-04-14 00:00:00Z]},
        %{source_item_id: "a", url: "https://mock/a", title: "A", timestamp: ~U[2026-04-13 00:00:00Z]}
      ]]
    end
  end

  defmodule BoomBackend do
    @behaviour Cham.Subscriptions.Backend
    def id, do: :boom
    def name, do: "Boom"
    def stream_pages(_url), do: Stream.map([1], fn _ -> raise "kaboom" end)
  end

  setup do
    # BackendRegistry is supervised via the application in tests; ensure it exists.
    case Process.whereis(Cham.Subscriptions.BackendRegistry) do
      nil -> {:ok, _} = start_supervised({BackendRegistry, []})
      _ -> :ok
    end

    :ok = BackendRegistry.register(MockBackend)
    :ok = BackendRegistry.register(BoomBackend)
    :ok
  end

  defp items_for(sub_id) do
    Repo.all(from i in Item, where: i.subscription_id == ^sub_id, order_by: [asc: i.source_item_id])
  end

  test "first poll (no prior items) creates items for all entries" do
    {:ok, sub} =
      Subscriptions.create_subscription(%{
        source_url: "https://mock.example/feed",
        backend: "mock",
        title: "Mock",
        poll_interval_seconds: 86_400
      })

    assert :ok = perform_job(PollWorker, %{"subscription_id" => sub.id})

    sub = Repo.reload!(sub)
    assert sub.last_polled_at != nil
    assert sub.consecutive_failures == 0

    items = items_for(sub.id)
    assert Enum.map(items, & &1.source_item_id) == ["a", "b"]
  end

  test "subsequent poll with already-seen item only ingests new" do
    {:ok, sub} =
      Subscriptions.create_subscription(%{
        source_url: "https://mock2.example/feed",
        backend: "mock",
        title: "Mock2",
        poll_interval_seconds: 86_400
      })

    {:ok, _} =
      Items.create_item(%{
        url: "https://mock/a",
        subscription_id: sub.id,
        source_item_id: "a"
      })

    assert :ok = perform_job(PollWorker, %{"subscription_id" => sub.id})

    ids = items_for(sub.id) |> Enum.map(& &1.source_item_id)
    assert "a" in ids
    assert "b" in ids
  end

  test "backend failure records last_error and increments consecutive_failures" do
    {:ok, sub} =
      Subscriptions.create_subscription(%{
        source_url: "https://boom.example/feed",
        backend: "boom",
        title: "Boom",
        poll_interval_seconds: 86_400
      })

    assert :ok = perform_job(PollWorker, %{"subscription_id" => sub.id})

    sub = Repo.reload!(sub)
    assert sub.consecutive_failures == 1
    assert sub.last_error =~ "kaboom"
    assert sub.last_polled_at != nil
  end
end
