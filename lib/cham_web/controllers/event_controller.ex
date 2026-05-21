defmodule ChamWeb.EventController do
  use ChamWeb, :controller

  alias Cham.Items
  alias Cham.Pipeline.Events.{StageCompleted, StageFailed, StageSnoozed, StageStarted}

  @terminal_statuses ~w(complete incomplete failed cancelled)
  @keepalive_interval 15_000

  def stream(conn, %{"id" => id}) do
    case Items.get_item_by_slug_or_id(id) do
      {:ok, item} ->
        if item.status in @terminal_statuses do
          conn
          |> put_resp_content_type("text/event-stream")
          |> send_resp(
            200,
            format_sse_event("item_status_changed", %{
              item_id: item.id,
              status: item.status
            })
          )
        else
          stream_events(conn, item)
        end

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> put_view(ChamWeb.ItemJSON)
        |> json(%{error: "not found"})

      {:error, :ambiguous} ->
        conn
        |> put_status(:conflict)
        |> put_view(ChamWeb.ItemJSON)
        |> json(%{error: "ambiguous id prefix"})
    end
  end

  defp stream_events(conn, item) do
    Cham.EventBus.subscribe("pipeline")
    Cham.EventBus.subscribe("item")

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> send_chunked(200)

    schedule_keepalive()
    listen_loop(conn, item.id)
  end

  defp listen_loop(conn, item_id) do
    receive do
      %StageStarted{item_id: ^item_id} = event ->
        case chunk_sse(conn, "stage_started", %{
               stage_id: event.stage_id,
               item_id: event.item_id,
               attempt: event.attempt
             }) do
          {:ok, conn} -> listen_loop(conn, item_id)
          {:error, _} -> conn
        end

      %StageCompleted{item_id: ^item_id} = event ->
        case chunk_sse(conn, "stage_completed", %{
               stage_id: event.stage_id,
               item_id: event.item_id,
               duration_ms: event.duration_ms
             }) do
          {:ok, conn} -> listen_loop(conn, item_id)
          {:error, _} -> conn
        end

      %StageFailed{item_id: ^item_id} = event ->
        case chunk_sse(conn, "stage_failed", %{
               stage_id: event.stage_id,
               item_id: event.item_id,
               error: event.error
             }) do
          {:ok, conn} -> listen_loop(conn, item_id)
          {:error, _} -> conn
        end

      %StageSnoozed{item_id: ^item_id} = event ->
        case chunk_sse(conn, "stage_snoozed", %{
               stage_id: event.stage_id,
               item_id: event.item_id,
               reason: event.reason
             }) do
          {:ok, conn} -> listen_loop(conn, item_id)
          {:error, _} -> conn
        end

      %{item_id: ^item_id, status: status} when status in @terminal_statuses ->
        chunk_sse(conn, "item_status_changed", %{item_id: item_id, status: status})
        conn

      :keepalive ->
        case Plug.Conn.chunk(conn, ": keepalive\n\n") do
          {:ok, conn} ->
            schedule_keepalive()
            listen_loop(conn, item_id)

          {:error, _} ->
            conn
        end

      _ ->
        listen_loop(conn, item_id)
    end
  end

  defp chunk_sse(conn, event_type, data) do
    sse_frame = format_sse_event(event_type, data)
    Plug.Conn.chunk(conn, sse_frame)
  end

  defp schedule_keepalive do
    Process.send_after(self(), :keepalive, @keepalive_interval)
  end

  @doc """
  Format a Server-Sent Event frame. Public for testing.
  """
  def format_sse_event(event_type, data) do
    json_data =
      case data do
        %{__struct__: _} -> data |> Map.from_struct() |> Jason.encode!()
        _ -> Jason.encode!(data)
      end

    "event: #{event_type}\ndata: #{json_data}\n\n"
  end
end
