defmodule Cham.Archive.LayoutTest do
  use ExUnit.Case, async: true

  alias Cham.Archive.Layout

  @dt ~U[2026-06-01 09:07:05Z]

  test "shorthash/1 is the first 8 hex chars of a uuid" do
    assert Layout.shorthash("a1b2c3d4-e5f6-7890-abcd-ef0123456789") == "a1b2c3d4"
  end

  test "slugify/1 lowercases, strips punctuation, hyphenates, caps at 80 chars" do
    assert Layout.slugify("Hello, World!") == "hello-world"
    assert Layout.slugify("  Multiple   Spaces--and-dashes ") == "multiple-spaces-and-dashes"
    assert String.length(Layout.slugify(String.duplicate("a", 200))) == 80
  end

  test "slugify/1 does not leave a trailing hyphen when the 80-char cap lands on one" do
    result = Layout.slugify(String.duplicate("a", 79) <> "-extra")
    assert String.length(result) <= 80
    refute String.ends_with?(result, "-")
  end

  test "timestamp/1 is ISO8601-basic UTC" do
    assert Layout.timestamp(@dt) == "20260601T090705Z"
  end

  test "date_path/1 is zero-padded YYYY/MM/DD" do
    assert Layout.date_path(@dt) == "2026/06/01"
  end

  test "item_archive_path/2 joins the date path and slug (relative, no archive/ prefix)" do
    assert Layout.item_archive_path("ingest-a1b2c3d4", @dt) == "2026/06/01/ingest-a1b2c3d4"
  end

  test "snapshot_path/1 is relative to the item dir" do
    assert Layout.snapshot_path("20260601T090705Z") == "snapshots/20260601T090705Z"
  end

  test "stage_path builds stages/<stage_id>-<ts>" do
    assert Cham.Archive.Layout.stage_path("extract_article", "20260601T090705Z") ==
             "stages/extract_article-20260601T090705Z"
  end

  test "item_abs_path/1 joins archive_root + archive/ + the relative archive_path" do
    # archive_root defaults to "." in test config.
    assert Layout.item_abs_path("2026/06/01/ingest-a1b2c3d4") ==
             "./archive/2026/06/01/ingest-a1b2c3d4"
  end
end

defmodule Cham.Archive.LayoutFilesystemTest do
  # async: false — these tests mutate the global :cham, :archive_root app env,
  # so they must not run concurrently with tests that read it.
  use ExUnit.Case, async: false

  alias Cham.Archive.Layout

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    prev = Application.get_env(:cham, :archive_root)
    Application.put_env(:cham, :archive_root, tmp_dir)
    on_exit(fn -> Application.put_env(:cham, :archive_root, prev) end)
    :ok
  end

  test "atomic_write/2 writes complete content and leaves no .tmp file", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "nested/deep/artifact.json")
    assert :ok = Layout.atomic_write(path, ~s({"ok":true}))
    assert File.read!(path) == ~s({"ok":true})
    assert Path.dirname(path) |> File.ls!() == ["artifact.json"]
  end

  test "create_item_dir/2 makes the dir and returns the relative archive_path" do
    dt = ~U[2026-06-01 09:07:05Z]
    assert {:ok, "2026/06/01/ingest-a1b2c3d4"} = Layout.create_item_dir("ingest-a1b2c3d4", dt)
    assert File.dir?(Layout.item_abs_path("2026/06/01/ingest-a1b2c3d4"))
  end

  test "re_slugify/2 renames the leaf within the same date dir and returns the new path" do
    dt = ~U[2026-06-01 09:07:05Z]
    {:ok, archive_path} = Layout.create_item_dir("ingest-a1b2c3d4", dt)
    File.write!(Path.join(Layout.item_abs_path(archive_path), "marker"), "x")

    assert {:ok, "2026/06/01/my-title-a1b2c3d4"} = Layout.re_slugify(archive_path, "My Title!")
    refute File.dir?(Layout.item_abs_path(archive_path))
    assert File.dir?(Layout.item_abs_path("2026/06/01/my-title-a1b2c3d4"))
    assert File.exists?(Path.join(Layout.item_abs_path("2026/06/01/my-title-a1b2c3d4"), "marker"))
  end
end
