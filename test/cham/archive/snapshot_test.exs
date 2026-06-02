defmodule Cham.Archive.SnapshotTest do
  use Cham.DataCase, async: true

  alias Cham.Archive.{Item, Snapshot}

  defp item_fixture do
    {:ok, item} =
      %Item{}
      |> Item.create_changeset(%{
        slug: "ingest-a1b2c3d4",
        archive_path: "2026/06/01/ingest-a1b2c3d4",
        first_captured_at: ~U[2026-06-01 12:00:00Z]
      })
      |> Repo.insert()

    item
  end

  test "accepts valid attrs and stores provenance map" do
    item = item_fixture()

    attrs = %{
      item_id: item.id,
      captured_at: ~U[2026-06-01 12:00:00Z],
      snapshot_path: "snapshots/20260601T120000Z/",
      provenance: %{"kind" => "cli", "agent" => "cham-cli/0.1"}
    }

    {:ok, snap} = %Snapshot{} |> Snapshot.changeset(attrs) |> Repo.insert()
    assert snap.provenance["kind"] == "cli"
  end

  test "requires item_id, captured_at, snapshot_path" do
    cs = Snapshot.changeset(%Snapshot{}, %{})
    refute cs.valid?
    assert %{item_id: _, captured_at: _, snapshot_path: _} = errors_on(cs)
  end
end
