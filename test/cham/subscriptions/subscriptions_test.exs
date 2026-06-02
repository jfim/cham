defmodule Cham.SubscriptionsTest do
  use Cham.DataCase, async: false

  alias Cham.Subscriptions
  alias Cham.Subscriptions.Subscription

  test "create_subscription/1 persists and returns struct" do
    {:ok, %Subscription{} = sub} =
      Subscriptions.create_subscription(%{
        source_url: "https://example.com/feed.xml",
        backend: "cham_rss",
        title: "Example",
        poll_interval_seconds: 86_400
      })

    assert sub.source_url == "https://example.com/feed.xml"
    assert sub.active == true
  end

  test "get_by_source_url/1 returns an existing subscription" do
    {:ok, sub} =
      Subscriptions.create_subscription(%{
        source_url: "https://example.com/feed.xml",
        backend: "cham_rss",
        title: "Example",
        poll_interval_seconds: 86_400
      })

    assert %Subscription{id: id} = Subscriptions.get_by_source_url("https://example.com/feed.xml")
    assert id == sub.id
  end

  test "get_by_source_url/1 returns nil for unknown URL" do
    assert nil == Subscriptions.get_by_source_url("https://example.com/other.xml")
  end

  test "list_due/1 returns active subscriptions whose interval has elapsed" do
    now = DateTime.utc_now()

    {:ok, fresh} =
      Subscriptions.create_subscription(%{
        source_url: "https://a.example/feed",
        backend: "cham_rss",
        title: "Fresh",
        poll_interval_seconds: 86_400
      })

    {:ok, _} = Subscriptions.update_subscription(fresh, %{last_polled_at: now})

    {:ok, stale} =
      Subscriptions.create_subscription(%{
        source_url: "https://b.example/feed",
        backend: "cham_rss",
        title: "Stale",
        poll_interval_seconds: 3600
      })

    {:ok, _} =
      Subscriptions.update_subscription(stale, %{
        last_polled_at: DateTime.add(now, -7200, :second)
      })

    due_urls = Subscriptions.list_due(now) |> Enum.map(& &1.source_url)
    assert "https://b.example/feed" in due_urls
    refute "https://a.example/feed" in due_urls
  end
end
