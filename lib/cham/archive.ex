defmodule Cham.Archive do
  @moduledoc """
  Primitive building blocks over the v3 archive substrate (schemas + on-disk
  Layout + Identity). Write functions are disk-first, DB-second: the filesystem
  archive is the source of truth and Postgres is a rebuildable index, so a crash
  between the two leaves a reindex-recoverable on-disk item.

  The orchestrated, transactional submit path (dedup-fallback + capture enqueue)
  is Phase 4 — not here.
  """

  alias Cham.Archive.{Item, Layout, Snapshot, UrlIdentity}
  alias Cham.Identity
  alias Cham.Repo

  @doc """
  Create a brand-new item from a submitted URL.

  Disk-first: generate the uuid in app code, create the on-disk item dir and the
  first snapshot's input record, then insert (in one transaction) the `items`
  row (`status: bootstrapping`, `slug: ingest-<shorthash>`), the
  `url_identities(role: submitted)` row, and the first `snapshots` row.

  Returns `{:ok, item, snapshot}`. A `unique(url_hash)` violation (concurrent
  first-submit race) returns `{:error, :exists}`; the on-disk dir is left for
  reindex/Phase 4 to reconcile.
  """
  @spec create_item_with_identity(String.t(), map()) ::
          {:ok, Item.t(), Snapshot.t()} | {:error, :exists}
  def create_item_with_identity(submitted_url, provenance) when is_binary(submitted_url) do
    id = Ecto.UUID.generate()
    shorthash = Layout.shorthash(id)
    slug = "ingest-#{shorthash}"
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    ts = Layout.timestamp(now)
    snapshot_path = Layout.snapshot_path(ts)

    normalized = Identity.normalize(submitted_url)
    url_hash = Identity.hash(normalized)

    # --- disk first ---
    {:ok, archive_path} = Layout.create_item_dir(slug, now)
    :ok = write_input_record(archive_path, snapshot_path, ts, provenance, submitted_url, url_hash)

    # --- then DB ---
    Ecto.Multi.new()
    |> Ecto.Multi.insert(
      :item,
      Item.create_changeset(%Item{id: id}, %{
        slug: slug,
        status: "bootstrapping",
        archive_path: archive_path,
        first_captured_at: now
      })
    )
    |> Ecto.Multi.insert(
      :identity,
      UrlIdentity.changeset(%UrlIdentity{}, %{
        item_id: id,
        url_hash: url_hash,
        normalized_url: normalized,
        role: "submitted"
      })
    )
    |> Ecto.Multi.insert(
      :snapshot,
      Snapshot.changeset(%Snapshot{}, %{
        item_id: id,
        captured_at: now,
        provenance: provenance,
        snapshot_path: snapshot_path
      })
    )
    |> Repo.transaction()
    |> case do
      {:ok, %{item: item, snapshot: snapshot}} ->
        {:ok, item, snapshot}

      {:error, :identity, %Ecto.Changeset{errors: errors}, _changes} ->
        if Keyword.has_key?(errors, :url_hash) do
          {:error, :exists}
        else
          raise "unexpected url_identity changeset error: #{inspect(errors)}"
        end

      {:error, step, value, _changes} ->
        raise "unexpected Ecto.Multi failure at step #{inspect(step)}: #{inspect(value)}"
    end
  end

  @doc """
  Atomic write of `snapshots/<ts>/input-<ts>/artifact.json` recording the submit
  origin: `{provenance, submitted_url, submitted_hash}`.
  """
  @spec write_input_record(String.t(), String.t(), String.t(), map(), String.t(), String.t()) ::
          :ok
  def write_input_record(
        archive_path,
        snapshot_path,
        ts,
        provenance,
        submitted_url,
        submitted_hash
      ) do
    record_path =
      Path.join([
        Layout.item_abs_path(archive_path),
        snapshot_path,
        "input-#{ts}",
        "artifact.json"
      ])

    content =
      Jason.encode!(%{
        "provenance" => provenance,
        "submitted_url" => submitted_url,
        "submitted_hash" => submitted_hash
      })

    Layout.atomic_write(record_path, content)
  end
end
