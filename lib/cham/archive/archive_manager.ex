defmodule Cham.Archive.ArchiveManager do
  @moduledoc """
  Archive-aware filesystem operations. Encodes the archive directory layout
  (archive/YYYY/MM/DD/<slug>/processing/<stage>-<timestamp>) and delegates
  actual FS operations to `Cham.Archive.FilesystemManager`.
  """

  alias Cham.Archive.FilesystemManager

  @doc """
  Returns the archive path for an item identified by slug and date.

  Layout: `<root>/archive/YYYY/MM/DD/<slug>`
  """
  def item_path(root, slug, %Date{} = date) do
    year = date.year |> Integer.to_string()
    month = date.month |> Integer.to_string() |> String.pad_leading(2, "0")
    day = date.day |> Integer.to_string() |> String.pad_leading(2, "0")
    Path.join([root, "archive", year, month, day, slug])
  end

  @doc """
  Returns the bootstrap staging path for an item being ingested.

  Layout: `<root>/tmp/bootstrap/<item_id>`
  """
  def bootstrap_path(root, item_id) do
    Path.join([root, "tmp", "bootstrap", item_id])
  end

  @doc """
  Creates a timestamped processing directory for a pipeline stage.

  Layout: `<item_dir>/processing/<plugin_id>-<YYYYMMDDTHHMMSSz>`
  """
  def create_stage_dir(item_dir, plugin_id) do
    timestamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")
    dir_name = "#{plugin_id}-#{timestamp}"
    full_path = Path.join([item_dir, "processing", dir_name])
    FilesystemManager.mkdir_p(full_path)
    {:ok, full_path}
  end

  @doc """
  Moves a bootstrap directory to its final archive location.
  """
  def move_to_archive(root, bootstrap_path, slug, %Date{} = date) do
    archive_path = item_path(root, slug, date)
    FilesystemManager.mkdir_p(Path.dirname(archive_path))
    :ok = FilesystemManager.move(bootstrap_path, archive_path)
    {:ok, archive_path}
  end

  @doc """
  Lists all item directories in the archive, returning maps with `:slug` and `:path`.
  """
  def list_items(root) do
    archive_dir = Path.join(root, "archive")

    if File.dir?(archive_dir) do
      archive_dir
      |> Path.join("**/*")
      |> Path.wildcard()
      |> Enum.filter(fn path ->
        File.dir?(path) and File.dir?(Path.join(path, "processing"))
      end)
      |> Enum.map(fn path ->
        %{slug: Path.basename(path), path: path}
      end)
    else
      []
    end
  end

  @doc """
  Lists processing stage directories for an item, sorted by name.
  """
  def list_stage_dirs(item_dir) do
    proc_dir = Path.join(item_dir, "processing")

    if File.dir?(proc_dir) do
      proc_dir
      |> File.ls!()
      |> Enum.sort()
      |> Enum.map(&Path.join(proc_dir, &1))
      |> Enum.filter(&File.dir?/1)
    else
      []
    end
  end
end
