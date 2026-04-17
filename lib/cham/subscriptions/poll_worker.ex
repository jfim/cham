defmodule Cham.Subscriptions.PollWorker do
  use Oban.Worker, queue: :subscriptions, max_attempts: 1

  import Ecto.Query

  alias Cham.Repo
  alias Cham.Subscriptions
  alias Cham.Subscriptions.{BackendRegistry, Backfill}
  alias Cham.Items.Item

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"subscription_id" => id} = args}) do
    sub = Subscriptions.get_subscription!(id)
    mode = parse_backfill(args["backfill"])

    try do
      {:ok, backend} = BackendRegistry.lookup(String.to_existing_atom(sub.backend))

      new_entries =
        backend.stream_pages(sub.source_url)
        |> Enum.reduce_while([], fn page, acc ->
          page_ids = Enum.map(page, & &1.source_item_id)
          already_seen = seen_source_ids(sub.id, page_ids)

          new_in_page = Enum.reject(page, fn e -> e.source_item_id in already_seen end)

          cond do
            page == [] ->
              {:halt, acc}

            new_in_page == [] ->
              {:halt, acc}

            true ->
              {:cont, acc ++ new_in_page}
          end
        end)

      {:ingest, ingest_entries, :seen, seen_entries} = Backfill.select(new_entries, mode)

      Enum.each(ingest_entries, fn e -> enqueue_ingest(sub, e) end)
      Enum.each(seen_entries, fn e -> record_seen(sub, e) end)

      Subscriptions.update_subscription(sub, %{
        last_polled_at: DateTime.utc_now(),
        last_error: nil,
        consecutive_failures: 0
      })

      :ok
    rescue
      e ->
        Logger.error("Subscription #{sub.id} poll failed: #{Exception.message(e)}")

        Subscriptions.update_subscription(sub, %{
          last_polled_at: DateTime.utc_now(),
          last_error: Exception.message(e),
          consecutive_failures: sub.consecutive_failures + 1
        })

        :ok
    end
  end

  defp seen_source_ids(_subscription_id, []), do: []

  defp seen_source_ids(subscription_id, ids) do
    Repo.all(
      from i in Item,
        where: i.subscription_id == ^subscription_id and i.source_item_id in ^ids,
        select: i.source_item_id
    )
  end

  defp enqueue_ingest(sub, entry) do
    # Create the item directly so the PollWorker doesn't depend on filesystem
    # bootstrap. The orchestrator will handle bootstrapping when it picks it up.
    case Cham.Items.create_item(%{
           url: entry.url,
           subscription_id: sub.id,
           source_item_id: entry.source_item_id,
           title: entry.title
         }) do
      {:ok, item} ->
        Cham.Pipeline.Orchestrator.kick_off(item.id)
        {:ok, item}

      {:error, reason} ->
        Logger.warning("Failed to create item for #{entry.url}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp record_seen(sub, entry) do
    Cham.Items.create_item(%{
      url: entry.url,
      subscription_id: sub.id,
      source_item_id: entry.source_item_id,
      title: entry.title,
      status: "complete"
    })
  end

  defp parse_backfill(nil), do: :none
  defp parse_backfill("none"), do: :none
  defp parse_backfill(%{"mode" => "last_n", "n" => n}) when is_integer(n), do: {:last_n, n}

  defp parse_backfill(%{"mode" => "since", "date" => d}) do
    {:ok, dt, _} = DateTime.from_iso8601(d)
    {:since, dt}
  end
end
