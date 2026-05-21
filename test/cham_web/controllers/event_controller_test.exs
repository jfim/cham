defmodule ChamWeb.EventControllerTest do
  use ChamWeb.ConnCase

  alias Cham.Items
  alias Cham.Pipeline.Events.{StageCompleted, StageFailed, StageStarted}

  describe "GET /api/v1/items/:id/events" do
    test "returns 404 for non-existent item", %{conn: conn} do
      conn = get(conn, "/api/v1/items/#{Ecto.UUID.generate()}/events")
      assert %{"error" => "not found"} = json_response(conn, 404)
    end

    test "returns event stream for terminal item with current status", %{conn: conn} do
      {:ok, item} = Items.create_item(%{url: "https://example.com/sse-1", status: "complete"})

      conn = get(conn, "/api/v1/items/#{item.id}/events")
      assert {"content-type", "text/event-stream; charset=utf-8"} in conn.resp_headers
      assert conn.resp_body =~ "event: item_status_changed"
      assert conn.resp_body =~ "complete"
    end
  end

  describe "event formatting" do
    test "format_sse_event/2 formats stage_started" do
      event = %StageStarted{stage_id: "download", item_id: "abc", attempt: 1}
      result = ChamWeb.EventController.format_sse_event("stage_started", event)
      assert result =~ "event: stage_started\n"
      assert result =~ "\"stage_id\":\"download\""
    end

    test "format_sse_event/2 formats stage_completed" do
      event = %StageCompleted{stage_id: "download", item_id: "abc", duration_ms: 500}
      result = ChamWeb.EventController.format_sse_event("stage_completed", event)
      assert result =~ "event: stage_completed\n"
      assert result =~ "\"duration_ms\":500"
    end

    test "format_sse_event/2 formats stage_failed" do
      event = %StageFailed{stage_id: "download", item_id: "abc", error: "timeout"}
      result = ChamWeb.EventController.format_sse_event("stage_failed", event)
      assert result =~ "event: stage_failed\n"
      assert result =~ "\"error\":\"timeout\""
    end
  end
end
