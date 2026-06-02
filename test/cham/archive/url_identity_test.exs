defmodule Cham.Archive.UrlIdentityTest do
  use Cham.DataCase, async: true

  alias Cham.Archive.{Item, UrlIdentity}

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

  defp valid(item) do
    %{
      item_id: item.id,
      url_hash: "deadbeef",
      normalized_url: "https://example.com/a",
      role: "submitted"
    }
  end

  test "accepts valid attrs" do
    item = item_fixture()
    assert %{valid?: true} = UrlIdentity.changeset(%UrlIdentity{}, valid(item))
  end

  test "rejects an unknown role" do
    item = item_fixture()
    cs = UrlIdentity.changeset(%UrlIdentity{}, %{valid(item) | role: "canonical"})
    refute cs.valid?
    assert %{role: _} = errors_on(cs)
  end

  test "enforces unique url_hash" do
    item = item_fixture()
    {:ok, _} = %UrlIdentity{} |> UrlIdentity.changeset(valid(item)) |> Repo.insert()
    {:error, cs} = %UrlIdentity{} |> UrlIdentity.changeset(valid(item)) |> Repo.insert()
    assert %{url_hash: _} = errors_on(cs)
  end
end
