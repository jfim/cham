defmodule ChamWeb.SubscriptionLiveTest do
  use ChamWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Cham.Subscriptions

  test "index lists subscriptions with title and source", %{conn: conn} do
    {:ok, sub} =
      Subscriptions.create_subscription(%{
        source_url: "https://idx.example/feed",
        backend: "cham_rss",
        title: "Index Example",
        poll_interval_seconds: 86_400
      })

    {:ok, _view, html} = live(conn, "/subscriptions")
    assert html =~ "Index Example"
    assert html =~ "https://idx.example/feed"
    assert html =~ sub.id
  end

  test "index surfaces last_error inline above threshold", %{conn: conn} do
    {:ok, sub} =
      Subscriptions.create_subscription(%{
        source_url: "https://fail.example/feed",
        backend: "cham_rss",
        title: "Failing",
        poll_interval_seconds: 86_400
      })

    {:ok, _} =
      Subscriptions.update_subscription(sub, %{
        consecutive_failures: 7,
        last_error: "connection refused"
      })

    {:ok, _view, html} = live(conn, "/subscriptions")
    assert html =~ "connection refused"
  end

  test "index shows empty state when no subscriptions", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/subscriptions")
    assert html =~ "No subscriptions yet"
  end

  test "item detail shows 'from {subscription.title}' when item has a subscription_id", %{
    conn: conn
  } do
    start_supervised!({Cham.JobTracking.Tracker, name: Cham.JobTracking.Tracker})

    {:ok, sub} =
      Cham.Subscriptions.create_subscription(%{
        source_url: "https://p.example/f",
        backend: "cham_rss",
        title: "My Feed",
        poll_interval_seconds: 86_400
      })

    {:ok, item} =
      Cham.Items.create_item(%{
        url: "https://p.example/item",
        subscription_id: sub.id,
        source_item_id: "p1"
      })

    {:ok, _view, html} = live(conn, "/items/#{item.id}")
    assert html =~ "from"
    assert html =~ "My Feed"
  end

  test "show page lists items for the subscription and supports rename", %{conn: conn} do
    {:ok, sub} =
      Cham.Subscriptions.create_subscription(%{
        source_url: "https://s.example/f",
        backend: "cham_rss",
        title: "Original",
        poll_interval_seconds: 86_400
      })

    {:ok, _item} =
      Cham.Items.create_item(%{
        url: "https://s.example/x",
        subscription_id: sub.id,
        source_item_id: "x",
        title: "An item"
      })

    {:ok, view, html} = live(conn, "/subscriptions/#{sub.id}")
    assert html =~ "Original"
    assert html =~ "An item"

    view
    |> form("#settings-form",
      subscription: %{title: "Renamed", poll_interval_seconds: "86400", active: "true"}
    )
    |> render_submit()

    sub = Cham.Repo.reload!(sub)
    assert sub.title == "Renamed"
  end

  test "feed item page shows Subscribe form with prefilled title", %{conn: conn} do
    start_supervised!({Cham.JobTracking.Tracker, name: Cham.JobTracking.Tracker})

    # Create a feed item with a feed_metadata artifact.
    {:ok, item} =
      Cham.Items.create_item(%{
        url: "https://feedui.example/rss.xml",
        content_type: "feed"
      })

    tmp = Path.join(System.tmp_dir!(), "subs_ui_test_#{System.unique_integer([:positive])}")
    artifact_dir = Path.join(tmp, "extract_feed_items")
    File.mkdir_p!(artifact_dir)

    File.write!(
      Path.join(artifact_dir, "feed_metadata.json"),
      Jason.encode!(%{
        "title" => "My Feed",
        "description" => "the description",
        "subscription_backend" => "cham_rss",
        "entries" => [
          %{
            "title" => "Entry One",
            "url" => "https://feedui.example/1",
            "timestamp" => "2026-04-14T00:00:00Z"
          }
        ]
      })
    )

    {:ok, item} = Cham.Items.update_item(item, %{bootstrap_path: tmp})

    {:ok, _artifact} =
      Cham.Items.create_artifact(%{
        item_id: item.id,
        labels: %{"origin" => "derived", "type" => "feed_metadata"},
        filenames: ["feed_metadata.json"],
        path: "extract_feed_items",
        stage: "extract_feed_items"
      })

    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, _view, html} = live(conn, "/items/#{item.id}")
    assert html =~ "Subscribe to My Feed"
    assert html =~ "the description"
    assert html =~ "Entry One"
    # Title field should be prefilled
    assert html =~ ~s(value="My Feed")
  end

  test "feed item with existing subscription shows View existing subscription link", %{conn: conn} do
    start_supervised!({Cham.JobTracking.Tracker, name: Cham.JobTracking.Tracker})

    {:ok, sub} =
      Cham.Subscriptions.create_subscription(%{
        source_url: "https://existing.example/feed.xml",
        backend: "cham_rss",
        title: "Existing",
        poll_interval_seconds: 86_400
      })

    {:ok, item} =
      Cham.Items.create_item(%{
        url: "https://existing.example/feed.xml",
        content_type: "feed"
      })

    {:ok, _view, html} = live(conn, "/items/#{item.id}")
    assert html =~ "View existing subscription"
    assert html =~ ~p"/subscriptions/#{sub.id}"
    refute html =~ "Subscribe to"
  end
end
