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

  describe "subscribe_from_item/2" do
    setup do
      # Create a feed item with a feed_metadata artifact.
      {:ok, item} =
        Cham.Items.create_item(%{
          url: "https://feed.example/rss.xml",
          content_type: "feed"
        })

      # Create a bootstrap/archive dir the artifact can resolve against.
      tmp = Path.join(System.tmp_dir!(), "sub_from_item_#{System.unique_integer([:positive])}")
      artifact_dir = Path.join(tmp, "extract_feed_items")
      File.mkdir_p!(artifact_dir)

      File.write!(
        Path.join(artifact_dir, "feed_metadata.json"),
        Jason.encode!(%{
          "title" => "Feed Title",
          "description" => "desc",
          "subscription_backend" => "cham_rss",
          "entries" => []
        })
      )

      {:ok, item} = Cham.Items.update_item(item, %{bootstrap_path: tmp})

      {:ok, _artifact} =
        Cham.Items.create_artifact(%{
          item_id: item.id,
          stage: "extract_feed_items",
          labels: %{"origin" => "derived", "type" => "feed_metadata"},
          filenames: ["feed_metadata.json"],
          path: "extract_feed_items"
        })

      on_exit(fn -> File.rm_rf!(tmp) end)

      {:ok, item: item}
    end

    test "uses feed metadata title when no override given", %{item: item} do
      assert {:ok, sub} = Cham.Subscriptions.subscribe_from_item(item.id, %{})
      assert sub.title == "Feed Title"
      assert sub.backend == "cham_rss"
      assert sub.source_url == "https://feed.example/rss.xml"
    end

    test "uses user override title if provided", %{item: item} do
      assert {:ok, sub} =
               Cham.Subscriptions.subscribe_from_item(item.id, %{title: "My Rename"})

      assert sub.title == "My Rename"
    end
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

    {:ok, _} = Subscriptions.update_subscription(stale, %{
      last_polled_at: DateTime.add(now, -7200, :second)
    })

    due_urls = Subscriptions.list_due(now) |> Enum.map(& &1.source_url)
    assert "https://b.example/feed" in due_urls
    refute "https://a.example/feed" in due_urls
  end
end
