defmodule Cham.Archive.FilesystemManagerTest do
  use ExUnit.Case, async: true

  alias Cham.Archive.FilesystemManager

  setup do
    tmp = Path.join(System.tmp_dir!(), "cham_fs_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    %{tmp: tmp}
  end

  describe "mkdir_p/1" do
    test "creates nested directories", %{tmp: tmp} do
      path = Path.join([tmp, "a", "b", "c"])
      assert :ok = FilesystemManager.mkdir_p(path)
      assert File.dir?(path)
    end

    test "succeeds if directory already exists", %{tmp: tmp} do
      assert :ok = FilesystemManager.mkdir_p(tmp)
    end
  end

  describe "atomic_write/2" do
    test "writes file content atomically", %{tmp: tmp} do
      path = Path.join(tmp, "test.txt")
      assert :ok = FilesystemManager.atomic_write(path, "hello world")
      assert File.read!(path) == "hello world"
    end

    test "creates parent directories if needed", %{tmp: tmp} do
      path = Path.join([tmp, "sub", "dir", "test.txt"])
      assert :ok = FilesystemManager.atomic_write(path, "content")
      assert File.read!(path) == "content"
    end

    test "no temp file left behind on success", %{tmp: tmp} do
      path = Path.join(tmp, "clean.txt")
      FilesystemManager.atomic_write(path, "data")
      files = File.ls!(tmp)
      assert files == ["clean.txt"]
    end
  end

  describe "move/2" do
    test "moves a file", %{tmp: tmp} do
      src = Path.join(tmp, "src.txt")
      dst = Path.join(tmp, "dst.txt")
      File.write!(src, "data")

      assert :ok = FilesystemManager.move(src, dst)
      refute File.exists?(src)
      assert File.read!(dst) == "data"
    end

    test "moves a directory tree", %{tmp: tmp} do
      src = Path.join(tmp, "src_dir")
      dst = Path.join(tmp, "dst_dir")
      File.mkdir_p!(Path.join(src, "sub"))
      File.write!(Path.join([src, "sub", "file.txt"]), "nested")

      assert :ok = FilesystemManager.move(src, dst)
      refute File.exists?(src)
      assert File.read!(Path.join([dst, "sub", "file.txt"])) == "nested"
    end

    test "creates parent directories for destination", %{tmp: tmp} do
      src = Path.join(tmp, "src.txt")
      dst = Path.join([tmp, "new", "path", "dst.txt"])
      File.write!(src, "data")

      assert :ok = FilesystemManager.move(src, dst)
      assert File.read!(dst) == "data"
    end
  end
end
