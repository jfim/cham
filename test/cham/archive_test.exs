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

  @tag :tmp_dir
  test "lookup_item_by_url delegates to Identity (item_id or nil)" do
    {:ok, item, _snap} = Archive.create_item_with_identity(@url, @provenance)
    assert Archive.lookup_item_by_url(@url) == item.id
    assert Archive.lookup_item_by_url("https://example.com/other") == nil
  end

  @tag :tmp_dir
  test "add_redirect_aliases inserts redirect_alias rows for normalized URLs" do
    {:ok, item, _snap} = Archive.create_item_with_identity(@url, @provenance)
    alias_url = Identity.normalize("https://example.com/redirected")

    assert {:ok, [alias_row]} = Archive.add_redirect_aliases(item, [alias_url])
    assert alias_row.role == "redirect_alias"
    assert alias_row.item_id == item.id
    assert alias_row.url_hash == Identity.hash(alias_url)
  end

  @tag :tmp_dir
  test "re_slugify renames the dir and updates slug + archive_path (rename-first)" do
    {:ok, item, _snap} = Archive.create_item_with_identity(@url, @provenance)
    old_path = item.archive_path
    shorthash = Layout.shorthash(item.id)

    assert {:ok, updated} = Archive.re_slugify(item, "My Great Title!")
    assert updated.slug == "my-great-title-#{shorthash}"
    assert updated.archive_path =~ ~r{/my-great-title-#{shorthash}\z}
    assert Repo.get!(Item, item.id).archive_path == updated.archive_path
    refute File.dir?(Layout.item_abs_path(old_path))
    assert File.dir?(Layout.item_abs_path(updated.archive_path))
  end

  @tag :tmp_dir
  test "thin insert helpers round-trip snapshot/component/artifact" do
    {:ok, item, snapshot} = Archive.create_item_with_identity(@url, @provenance)

    {:ok, snap2} =
      Archive.create_snapshot(item, %{
        captured_at: DateTime.utc_now() |> DateTime.truncate(:second),
        provenance: @provenance,
        snapshot_path: "snapshots/20260601T100000Z"
      })

    assert snap2.item_id == item.id

    {:ok, component} = Archive.create_component(snapshot, %{content_type: "article"})
    assert component.snapshot_id == snapshot.id
    assert component.content_type == "article"

    {:ok, artifact} =
      Archive.record_artifact(snapshot, %{
        component_id: component.id,
        category: "extracted",
        stage: "extract_article",
        path: "snapshots/x/components/article",
        version: 1
      })

    assert artifact.snapshot_id == snapshot.id
    assert artifact.component_id == component.id
    assert artifact.status == "produced"
  end
end
