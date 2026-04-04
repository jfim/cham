defmodule ChamWeb.DashboardLiveTest do
  use ChamWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Cham.Items

  setup do
    {:ok, article} =
      Items.create_item(%{
        url: "https://example.com/article",
        title: "Test Article",
        content_type: "article",
        tags: ["elixir"],
        status: "complete"
      })

    {:ok, video} =
      Items.create_item(%{
        url: "https://example.com/video",
        title: "Test Video",
        content_type: "video",
        tags: ["phoenix"],
        status: "complete"
      })

    {:ok, processing} =
      Items.create_item(%{
        url: "https://example.com/processing",
        status: "processing"
      })

    %{article: article, video: video, processing: processing}
  end

  describe "mount" do
    test "renders dashboard with hero text", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "Cham knows about"
      assert html =~ "pieces of information"
    end

    test "shows items in the list", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "Test Article"
      assert html =~ "Test Video"
    end

    test "shows content type facets in sidebar", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "Articles"
      assert html =~ "Videos"
    end

    test "shows in-progress count", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "In Progress"
    end
  end

  describe "filtering" do
    test "filters by content type via URL param", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/?type=article")
      assert html =~ "Test Article"
      refute html =~ "Test Video"
    end

    test "filters by tag via URL param", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/?tag=elixir")
      assert html =~ "Test Article"
      refute html =~ "Test Video"
    end

    test "clicking content type applies filter", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      html = view |> element("[data-filter-type=\"article\"]") |> render_click()
      assert_patched(view, "/?type=article")
      assert html =~ "Test Article"
    end

    test "clicking active content type removes filter", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/?type=article")
      view |> element("[data-filter-type=\"article\"]") |> render_click()
      assert_patched(view, "/")
    end
  end

  describe "empty states" do
    test "shows empty archive message when no items", %{conn: conn} do
      Cham.Repo.delete_all(Cham.Items.Artifact)
      Cham.Repo.delete_all(Cham.Items.Item)
      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "Submit your first URL"
    end
  end

  describe "submit modal" do
    test "submitting a URL creates an item", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      view
      |> form("#submit-form", %{url: "https://example.com/new-item"})
      |> render_submit()

      flash = assert_redirected(view, "/")
      assert flash["info"] =~ "submitted"
    end

    test "submitting a duplicate URL shows error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      html =
        view
        |> form("#submit-form", %{url: "https://example.com/article"})
        |> render_submit()

      assert html =~ "already"
    end
  end
end
