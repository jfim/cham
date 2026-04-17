defmodule Cham.Subscriptions.BackfillTest do
  use ExUnit.Case, async: true

  alias Cham.Subscriptions.Backfill

  defp entry(id, ts) do
    %{source_item_id: id, url: "https://example.com/#{id}", title: id, timestamp: ts}
  end

  test "mode :none returns empty ingest set (everything marked seen)" do
    entries = [entry("b", ~U[2026-04-14 00:00:00Z]), entry("a", ~U[2026-04-13 00:00:00Z])]

    assert {:ingest, [], :seen, seen} = Backfill.select(entries, :none)
    assert length(seen) == 2
  end

  test "mode {:last_n, 1} ingests newest one" do
    entries = [entry("b", ~U[2026-04-14 00:00:00Z]), entry("a", ~U[2026-04-13 00:00:00Z])]

    assert {:ingest, ingest, :seen, seen} = Backfill.select(entries, {:last_n, 1})
    assert Enum.map(ingest, & &1.source_item_id) == ["b"]
    assert Enum.map(seen, & &1.source_item_id) == ["a"]
  end

  test "mode {:since, date} ingests entries on-or-after date" do
    entries = [
      entry("c", ~U[2026-04-14 00:00:00Z]),
      entry("b", ~U[2026-04-13 00:00:00Z]),
      entry("a", ~U[2026-04-10 00:00:00Z])
    ]

    assert {:ingest, ingest, :seen, seen} =
             Backfill.select(entries, {:since, ~U[2026-04-13 00:00:00Z]})

    assert Enum.map(ingest, & &1.source_item_id) == ["c", "b"]
    assert Enum.map(seen, & &1.source_item_id) == ["a"]
  end
end
