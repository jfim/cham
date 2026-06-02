defmodule Cham.Archive.EdgeTest do
  use Cham.DataCase, async: true

  alias Cham.Archive.{Edge, Item}

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

  test "accepts a dangling edge (no target_item_id)" do
    item = item_fixture()

    attrs = %{
      source_item_id: item.id,
      edge_type: "linked",
      target_url_hash: "cafebabe",
      provenance: "extractor"
    }

    {:ok, edge} = %Edge{} |> Edge.changeset(attrs) |> Repo.insert()
    assert edge.target_item_id == nil
  end

  test "rejects unknown edge_type and provenance" do
    item = item_fixture()
    base = %{source_item_id: item.id, target_url_hash: "abc"}

    bad_type =
      Edge.changeset(%Edge{}, Map.merge(base, %{edge_type: "wat", provenance: "extractor"}))

    refute bad_type.valid?
    assert %{edge_type: _} = errors_on(bad_type)

    bad_prov =
      Edge.changeset(%Edge{}, Map.merge(base, %{edge_type: "embed", provenance: "robot"}))

    refute bad_prov.valid?
    assert %{provenance: _} = errors_on(bad_prov)
  end
end
