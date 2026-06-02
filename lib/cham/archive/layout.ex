defmodule Cham.Archive.Layout do
  @moduledoc """
  Authority on the v3 on-disk archive tree.

  Layout:

      <archive_root>/archive/YYYY/MM/DD/<slug>/        # item dir
        snapshots/<ts>/                                # snapshot dir
          input-<ts>/artifact.json                     # submit-path input record
          capture/                                      # snapshot-level capture (Phase 5)
          components/<type>/                            # extracted components (Phase 6)
        stages/<stage_id>-<ts>/                        # stage working dirs

  `<ts>` is ISO8601-basic (`YYYYMMDDTHHMMSSZ`). `archive_path` (stored on `items`)
  is the item dir **relative to the `archive/` subdir** — e.g.
  `"2026/06/01/ingest-a1b2c3d4"`.
  """

  @doc "Archive root from config (defaults to the cwd)."
  @spec archive_root() :: String.t()
  def archive_root, do: Application.get_env(:cham, :archive_root, ".")

  @doc "First 8 hex chars of an item uuid — the slug shorthash."
  @spec shorthash(Ecto.UUID.t()) :: String.t()
  def shorthash(uuid) when is_binary(uuid), do: String.slice(uuid, 0, 8)

  @doc "Title -> slug. Title only — there is no slugify(url) floor (reconciliation B3/B5)."
  @spec slugify(String.t()) :: String.t()
  def slugify(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s\-]/, "")
    |> String.replace(~r/[\s\-]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 80)
    |> String.trim_trailing("-")
  end

  @doc "ISO8601-basic UTC timestamp, e.g. `20260601T090705Z`."
  @spec timestamp(DateTime.t()) :: String.t()
  def timestamp(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y%m%dT%H%M%SZ")

  @doc "Zero-padded `YYYY/MM/DD` date shard."
  @spec date_path(DateTime.t()) :: String.t()
  def date_path(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y/%m/%d")

  @doc "Relative item archive_path: `YYYY/MM/DD/<slug>`."
  @spec item_archive_path(String.t(), DateTime.t()) :: String.t()
  def item_archive_path(slug, %DateTime{} = dt), do: Path.join(date_path(dt), slug)

  @doc "Absolute on-disk item dir for a relative archive_path."
  @spec item_abs_path(String.t()) :: String.t()
  def item_abs_path(archive_path), do: Path.join([archive_root(), "archive", archive_path])

  @doc "Relative snapshot dir (under the item dir): `snapshots/<ts>`."
  @spec snapshot_path(String.t()) :: String.t()
  def snapshot_path(ts) when is_binary(ts), do: Path.join("snapshots", ts)

  @doc """
  Atomic write: temp file + rename, so the file is complete-or-absent.
  Creates parent directories.
  """
  @spec atomic_write(String.t(), iodata()) :: :ok | {:error, File.posix()}
  def atomic_write(path, content) do
    dir = Path.dirname(path)
    File.mkdir_p!(dir)
    tmp_path = path <> ".tmp.#{:erlang.unique_integer([:positive])}"

    with :ok <- File.write(tmp_path, content) do
      File.rename(tmp_path, path)
    end
  end

  @doc """
  Create the item dir `<root>/archive/YYYY/MM/DD/<slug>/`. Returns the relative
  `archive_path`.
  """
  @spec create_item_dir(String.t(), DateTime.t()) :: {:ok, String.t()}
  def create_item_dir(slug, %DateTime{} = dt) do
    archive_path = item_archive_path(slug, dt)
    File.mkdir_p!(item_abs_path(archive_path))
    {:ok, archive_path}
  end

  @doc """
  Rename the leaf `ingest-<shorthash>` -> `<slugify(title)>-<shorthash>` within
  the same date dir (atomic, same filesystem). Returns the new relative
  `archive_path`. Set-once: the leaf is always `ingest-<shorthash>` at call time
  (reconciliation B3).
  """
  @spec re_slugify(String.t(), String.t()) :: {:ok, String.t()}
  def re_slugify(archive_path, title) when is_binary(title) do
    leaf = Path.basename(archive_path)
    date_dir = Path.dirname(archive_path)
    shorthash = String.replace_prefix(leaf, "ingest-", "")
    new_leaf = "#{slugify(title)}-#{shorthash}"
    new_archive_path = Path.join(date_dir, new_leaf)

    :ok = File.rename(item_abs_path(archive_path), item_abs_path(new_archive_path))
    {:ok, new_archive_path}
  end
end
