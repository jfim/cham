defmodule Cham.Subscriptions.PollWorker do
  use Oban.Worker, queue: :subscriptions, max_attempts: 1

  import Ecto.Query

  alias Cham.Items.Item
  alias Cham.Repo
  alias Cham.Subscriptions
  alias Cham.Subscriptions.{BackendRegistry, Backfill}

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"subscription_id" => id} = args}) do
    sub = Subscriptions.get_subscription!(id)
    mode = parse_backfill(args["backfill"])

    # For explicit re-backfill runs, entries previously marked as seen-only
    # should be re-considered. For cron/incremental polls, they stay deduped.
    reconsider_seen = mode not in [:none, :incremental]

    try do
      {:ok, backend} = BackendRegistry.lookup(String.to_existing_atom(sub.backend))

      new_entries =
        backend.stream_pages(sub.source_url)
        |> Enum.reduce_while([], fn page, acc ->
          page_ids = Enum.map(page, & &1.source_item_id)
          already_seen = seen_source_ids(sub.id, page_ids, reconsider_seen)

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

  defp seen_source_ids(_subscription_id, [], _), do: []

  # When reconsider_seen? is true (explicit re-backfill), ignore rows that
  # only exist to mark a source_item_id as seen during a prior backfill —
  # they should be eligible for ingest this time.
  defp seen_source_ids(subscription_id, ids, reconsider_seen?) do
    base =
      from i in Item,
        where: i.subscription_id == ^subscription_id and i.source_item_id in ^ids,
        select: i.source_item_id

    query =
      if reconsider_seen? do
        from i in base,
          where: fragment("COALESCE(?->>'backfill_seen', 'false')", i.metadata) != "true"
      else
        base
      end

    Repo.all(query)
  end

  defp enqueue_ingest(sub, entry) do
    # Remove any prior backfill-seen marker so submit_url can insert a new item
    # for this source_item_id without tripping the unique constraint.
    Repo.delete_all(
      from i in Item,
        where:
          i.subscription_id == ^sub.id and
            i.source_item_id == ^entry.source_item_id and
            fragment("COALESCE(?->>'backfill_seen', 'false')", i.metadata) == "true"
    )

    Cham.Pipeline.submit_url(entry.url,
      subscription_id: sub.id,
      source_item_id: entry.source_item_id,
      title: entry.title
    )
  end

  defp record_seen(sub, entry) do
    Cham.Items.create_item(%{
      url: entry.url,
      subscription_id: sub.id,
      source_item_id: entry.source_item_id,
      title: entry.title,
      status: "complete",
      metadata: %{"backfill_seen" => true}
    })
  end

  defp parse_backfill(nil), do: :incremental
  defp parse_backfill("incremental"), do: :incremental
  defp parse_backfill("none"), do: :none
  defp parse_backfill(%{"mode" => "last_n", "n" => n}) when is_integer(n), do: {:last_n, n}

  defp parse_backfill(%{"mode" => "since", "date" => d}) do
    {:ok, dt, _} = DateTime.from_iso8601(d)
    {:since, dt}
  end
end
