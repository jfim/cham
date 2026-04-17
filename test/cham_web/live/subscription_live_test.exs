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
    |> form("#settings-form", subscription: %{title: "Renamed", poll_interval_seconds: "86400", active: "true"})
    |> render_submit()

    sub = Cham.Repo.reload!(sub)
    assert sub.title == "Renamed"
  end
end
