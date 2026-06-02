defmodule Cham.ArchiveTest do
  use Cham.DataCase, async: false

  alias Cham.Archive
  alias Cham.Archive.{Item, Layout, Snapshot, UrlIdentity}
  alias Cham.Identity

  @url "https://example.com/article"
  @provenance %{"kind" => "manual", "actor" => "cli", "ref" => nil, "agent" => "test"}

  setup %{tmp_dir: tmp_dir} do
    prev = Application.get_env(:cham, :archive_root)
    Application.put_env(:cham, :archive_root, tmp_dir)
    on_exit(fn -> Application.put_env(:cham, :archive_root, prev) end)
    :ok
  end

  @tag :tmp_dir
  test "create_item_with_identity writes the rows, the on-disk dir, and the input record" do
    assert {:ok, item, snapshot} = Archive.create_item_with_identity(@url, @provenance)

    item = Repo.get!(Item, item.id)
    assert item.status == "bootstrapping"
    assert item.slug == "ingest-" <> Layout.shorthash(item.id)

    assert item.archive_path =~
             Regex.compile!("\\A\\d{4}/\\d{2}/\\d{2}/ingest-#{Layout.shorthash(item.id)}\\z")

    identity = Repo.get_by!(UrlIdentity, item_id: item.id)
    assert identity.role == "submitted"
    assert identity.url_hash == Identity.hash(Identity.normalize(@url))
    assert identity.normalized_url == Identity.normalize(@url)

    snapshot = Repo.get!(Snapshot, snapshot.id)
    assert snapshot.item_id == item.id
    assert snapshot.provenance == @provenance

    assert File.dir?(Layout.item_abs_path(item.archive_path))

    input_glob =
      Path.join([
        Layout.item_abs_path(item.archive_path),
        snapshot.snapshot_path,
        "input-*",
        "artifact.json"
      ])

    assert [record_path] = Path.wildcard(input_glob)
    record = record_path |> File.read!() |> Jason.decode!()
    assert record["submitted_url"] == @url
    assert record["submitted_hash"] == Identity.hash(Identity.normalize(@url))
    assert record["provenance"] == @provenance
  end

  @tag :tmp_dir
  test "create_item_with_identity returns {:error, :exists} on a duplicate url_hash" do
    assert {:ok, _item, _snap} = Archive.create_item_with_identity(@url, @provenance)
    dup = "HTTPS://Example.com/article?utm_source=x"
    assert {:error, :exists} = Archive.create_item_with_identity(dup, @provenance)
  end
end
