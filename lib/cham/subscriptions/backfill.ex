defmodule Cham.Subscriptions.Backfill do
  @moduledoc """
  Splits a list of feed entries into (ingest, seen) sets based on the
  selected backfill mode. The caller ingests the first set and marks
  the second set as already seen so they won't be re-discovered.
  """

  @type mode :: :none | :incremental | {:last_n, pos_integer()} | {:since, DateTime.t()}

  @spec select([map()], mode()) :: {:ingest, [map()], :seen, [map()]}
  def select(entries, :none), do: {:ingest, [], :seen, entries}

  def select(entries, :incremental), do: {:ingest, entries, :seen, []}

  def select(entries, {:last_n, n}) when is_integer(n) and n > 0 do
    {ingest, seen} = Enum.split(entries, n)
    {:ingest, ingest, :seen, seen}
  end

  def select(entries, {:since, %DateTime{} = cutoff}) do
    {ingest, seen} =
      Enum.split_with(entries, fn e ->
        case e.timestamp do
          nil -> false
          ts -> DateTime.compare(ts, cutoff) != :lt
        end
      end)

    {:ingest, ingest, :seen, seen}
  end
end
