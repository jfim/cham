defmodule ChamWeb.ItemDetailLiveTest do
  use ChamWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Cham.Items

  setup do
    start_supervised!({Cham.JobTracking.Tracker, name: Cham.JobTracking.Tracker})

    {:ok, item} =
      Items.create_item(%{
        url: "https://example.com/detail-test",
        title: "Test Article Detail",
        content_type: "article",
        tags: ["elixir", "testing"],
        status: "complete"
      })

    %{item: item}
  end

  describe "mount" do
    test "renders item detail with title", %{conn: conn, item: item} do
      {:ok, _view, html} = live(conn, ~p"/items/#{item.id}")
      assert html =~ "Test Article Detail"
    end

    test "shows back link", %{conn: conn, item: item} do
      {:ok, _view, html} = live(conn, ~p"/items/#{item.id}")
      assert html =~ "Back"
    end

    test "shows tag pills", %{conn: conn, item: item} do
      {:ok, _view, html} = live(conn, ~p"/items/#{item.id}")
      assert html =~ "elixir"
      assert html =~ "testing"
    end

    test "shows external link to source", %{conn: conn, item: item} do
      {:ok, _view, html} = live(conn, ~p"/items/#{item.id}")
      assert html =~ "example.com"
    end
  end

  describe "bottom pane tabs" do
    test "shows tab bar", %{conn: conn, item: item} do
      {:ok, _view, html} = live(conn, ~p"/items/#{item.id}")
      assert html =~ "Summary"
      assert html =~ "Metadata"
      assert html =~ "Chat"
    end

    test "clicking a tab shows its content", %{conn: conn, item: item} do
      {:ok, view, _html} = live(conn, ~p"/items/#{item.id}")
      html = view |> element("[data-tab=\"metadata\"]") |> render_click()
      assert html =~ item.url
    end
  end

  describe "content availability" do
    test "shows not-requested state when no artifacts", %{conn: conn, item: item} do
      {:ok, view, _html} = live(conn, ~p"/items/#{item.id}")
      html = view |> element("[data-tab=\"summary\"]") |> render_click()
      assert html =~ "Not available"
    end
  end

  describe "processing view" do
    test "shows status badge for processing items", %{conn: conn} do
      {:ok, processing} =
        Items.create_item(%{url: "https://example.com/processing-detail", status: "processing"})

      {:ok, _view, html} = live(conn, ~p"/items/#{processing.id}")
      assert html =~ "Processing"
    end
  end

  describe "real-time updates" do
    test "stage progress updates appear", %{conn: conn} do
      {:ok, processing} =
        Items.create_item(%{url: "https://example.com/realtime-detail", status: "processing"})

      {:ok, view, _html} = live(conn, ~p"/items/#{processing.id}")

      alias Cham.Pipeline.Events.StageStarted

      Cham.EventBus.publish("pipeline:stage_started", %StageStarted{
        stage_id: "summarize",
        item_id: processing.id,
        attempt: 1
      })

      Process.sleep(100)
      html = render(view)
      assert html =~ "summarize"
    end
  end
end
