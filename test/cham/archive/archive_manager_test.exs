defmodule Cham.Archive.ArchiveManagerTest do
  use ExUnit.Case, async: true

  alias Cham.Archive.ArchiveManager

  setup do
    root =
      Path.join(System.tmp_dir!(), "cham_archive_test_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  describe "item_path/3" do
    test "returns date-sharded archive path", %{root: root} do
      date = ~D[2026-04-02]
      path = ArchiveManager.item_path(root, "some-video-abc123", date)
      assert path == Path.join(root, "archive/2026/04/02/some-video-abc123")
    end
  end

  describe "bootstrap_path/2" do
    test "returns bootstrap staging path", %{root: root} do
      item_id = "550e8400-e29b-41d4-a716-446655440000"
      path = ArchiveManager.bootstrap_path(root, item_id)
      assert path == Path.join(root, "tmp/bootstrap/550e8400-e29b-41d4-a716-446655440000")
    end
  end

  describe "create_stage_dir/2" do
    test "creates a timestamped processing directory", %{root: root} do
      item_dir = Path.join(root, "test_item")
      File.mkdir_p!(item_dir)

      {:ok, stage_dir} = ArchiveManager.create_stage_dir(item_dir, "transcribe_whisper")

      assert File.dir?(stage_dir)
      assert stage_dir =~ ~r"processing/transcribe_whisper-\d{8}T\d{6}Z$"
    end

    test "two calls produce different directories", %{root: root} do
      item_dir = Path.join(root, "test_item2")
      File.mkdir_p!(item_dir)

      {:ok, dir1} = ArchiveManager.create_stage_dir(item_dir, "stage_a")
      Process.sleep(1100)
      {:ok, dir2} = ArchiveManager.create_stage_dir(item_dir, "stage_a")

      assert dir1 != dir2
    end
  end

  describe "move_to_archive/4" do
    test "moves bootstrap dir to archive location", %{root: root} do
      item_id = "test-item-id"
      bootstrap = ArchiveManager.bootstrap_path(root, item_id)
      File.mkdir_p!(Path.join(bootstrap, "processing/input-20260402T143000Z"))
      File.write!(Path.join(bootstrap, "processing/input-20260402T143000Z/artifact.json"), "{}")

      slug = "test-article-abc123"
      date = ~D[2026-04-02]

      assert {:ok, archive_path} = ArchiveManager.move_to_archive(root, bootstrap, slug, date)

      expected = Path.join(root, "archive/2026/04/02/test-article-abc123")
      assert archive_path == expected

      assert File.exists?(
               Path.join(archive_path, "processing/input-20260402T143000Z/artifact.json")
             )

      refute File.exists?(bootstrap)
    end
  end

  describe "list_items/1" do
    test "lists item directories in the archive", %{root: root} do
      archive = Path.join(root, "archive")
      File.mkdir_p!(Path.join(archive, "2026/04/02/video-abc/processing"))
      File.mkdir_p!(Path.join(archive, "2026/04/03/article-def/processing"))

      items = ArchiveManager.list_items(root)
      slugs = Enum.map(items, & &1.slug)
      assert "video-abc" in slugs
      assert "article-def" in slugs
      assert length(items) == 2
    end

    test "returns empty list for empty archive", %{root: root} do
      assert ArchiveManager.list_items(root) == []
    end
  end

  describe "list_stage_dirs/1" do
    test "lists processing directories for an item", %{root: root} do
      item_dir = Path.join(root, "test_item")
      proc = Path.join(item_dir, "processing")
      File.mkdir_p!(Path.join(proc, "input-20260402T143000Z"))
      File.mkdir_p!(Path.join(proc, "transcribe_whisper-20260402T144012Z"))

      dirs = ArchiveManager.list_stage_dirs(item_dir)
      assert length(dirs) == 2
      assert Enum.any?(dirs, &String.contains?(&1, "input-"))
      assert Enum.any?(dirs, &String.contains?(&1, "transcribe_whisper-"))
    end
  end
end
