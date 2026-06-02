defmodule Cham.Archive.ComponentTest do
  use Cham.DataCase, async: true

  alias Cham.Archive.{Component, Item, Snapshot}

  defp snapshot_fixture do
    {:ok, item} =
      %Item{}
      |> Item.create_changeset(%{
        slug: "ingest-a1b2c3d4",
        archive_path: "2026/06/01/ingest-a1b2c3d4",
        first_captured_at: ~U[2026-06-01 12:00:00Z]
      })
      |> Repo.insert()

    {:ok, snap} =
      %Snapshot{}
      |> Snapshot.changeset(%{
        item_id: item.id,
        captured_at: ~U[2026-06-01 12:00:00Z],
        snapshot_path: "snapshots/20260601T120000Z/"
      })
      |> Repo.insert()

    snap
  end

  test "accepts valid attrs" do
    snap = snapshot_fixture()
    cs = Component.changeset(%Component{}, %{snapshot_id: snap.id, content_type: "article"})
    assert cs.valid?
  end

  test "enforces one component per type per snapshot" do
    snap = snapshot_fixture()
    attrs = %{snapshot_id: snap.id, content_type: "article"}
    {:ok, _} = %Component{} |> Component.changeset(attrs) |> Repo.insert()
    {:error, cs} = %Component{} |> Component.changeset(attrs) |> Repo.insert()
    assert %{snapshot_id: _} = errors_on(cs)
  end
end
