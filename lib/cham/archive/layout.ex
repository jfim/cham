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
end
