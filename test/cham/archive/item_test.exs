defmodule Cham.Archive.ItemTest do
  use Cham.DataCase, async: true

  alias Cham.Archive.Item

  @valid %{
    slug: "ingest-a1b2c3d4",
    status: "bootstrapping",
    archive_path: "2026/06/01/ingest-a1b2c3d4",
    first_captured_at: ~U[2026-06-01 12:00:00Z]
  }

  test "create_changeset accepts valid attrs" do
    assert %{valid?: true} = Item.create_changeset(%Item{}, @valid)
  end

  test "create_changeset requires archive_path and first_captured_at" do
    cs = Item.create_changeset(%Item{}, Map.drop(@valid, [:archive_path, :first_captured_at]))
    refute cs.valid?
    assert %{archive_path: _, first_captured_at: _} = errors_on(cs)
  end

  test "rejects an unknown status" do
    cs = Item.create_changeset(%Item{}, %{@valid | status: "archived"})
    refute cs.valid?
    assert %{status: _} = errors_on(cs)
  end

  test "enforces unique archive_path" do
    {:ok, _} = %Item{} |> Item.create_changeset(@valid) |> Repo.insert()
    {:error, cs} = %Item{} |> Item.create_changeset(@valid) |> Repo.insert()
    assert %{archive_path: _} = errors_on(cs)
  end
end
