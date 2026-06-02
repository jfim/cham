defmodule Cham.Archive.ArtifactTest do
  use Cham.DataCase, async: true

  alias Cham.Archive.{Artifact, Item, Snapshot}

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

  test "accepts a snapshot-level capture artifact (no component)" do
    snap = snapshot_fixture()

    attrs = %{
      snapshot_id: snap.id,
      category: "capture",
      stage: "passe_partout_capture",
      path: "capture/stages/passe_partout_capture-20260601T120005Z/",
      filenames: ["capture.warc.gz", "capture.cdxj"],
      labels: %{"type" => "capture", "format" => "warc"},
      status: "produced",
      version: 1
    }

    {:ok, art} = %Artifact{} |> Artifact.changeset(attrs) |> Repo.insert()
    assert art.component_id == nil
    assert art.filenames == ["capture.warc.gz", "capture.cdxj"]
  end

  test "rejects unknown category and status" do
    snap = snapshot_fixture()
    base = %{snapshot_id: snap.id, stage: "x", path: "p"}

    bad_cat = Artifact.changeset(%Artifact{}, Map.put(base, :category, "bogus"))
    refute bad_cat.valid?
    assert %{category: _} = errors_on(bad_cat)

    bad_status =
      Artifact.changeset(%Artifact{}, Map.merge(base, %{category: "extracted", status: "weird"}))

    refute bad_status.valid?
    assert %{status: _} = errors_on(bad_status)
  end
end
