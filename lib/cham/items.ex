defmodule Cham.Items do
  import Ecto.Query

  alias Cham.Items.{Artifact, Item}
  alias Cham.Items.Events.ItemDeleted
  alias Cham.Repo

  def create_item(attrs) do
    %Item{}
    |> Item.create_changeset(attrs)
    |> Repo.insert()
  end

  def get_item(id), do: Repo.get(Item, id)

  def get_item!(id), do: Repo.get!(Item, id)

  def get_item_by_slug_or_id(id_or_slug) do
    case Repo.get_by(Item, slug: id_or_slug) do
      %Item{} = item ->
        {:ok, item}

      nil ->
        case Ecto.UUID.cast(id_or_slug) do
          {:ok, uuid} ->
            case Repo.get(Item, uuid) do
              %Item{} = item -> {:ok, item}
              nil -> {:error, :not_found}
            end

          :error ->
            lookup_by_id_prefix(id_or_slug)
        end
    end
  end

  @min_prefix_length 4

  defp lookup_by_id_prefix(input) do
    stripped = input |> String.replace("-", "") |> String.downcase()

    if byte_size(stripped) >= @min_prefix_length and
         Regex.match?(~r/^[0-9a-f]+$/, stripped) do
      pattern = stripped <> "%"

      matches =
        Repo.all(
          from i in Item,
            where: fragment("replace(?::text, '-', '') LIKE ?", i.id, ^pattern),
            limit: 2
        )

      case matches do
        [item] -> {:ok, item}
        [] -> {:error, :not_found}
        _ -> {:error, :ambiguous}
      end
    else
      {:error, :not_found}
    end
  end

  def update_item(%Item{} = item, attrs) do
    item
    |> Item.update_changeset(attrs)
    |> Repo.update()
  end

  def delete_item(%Item{} = item) do
    case Repo.delete(item) do
      {:ok, deleted} = result ->
        publish_deleted(deleted)
        result

      other ->
        other
    end
  end

  @doc """
  Delete an item and optionally its archive files.
  Files are deleted by default. Pass `keep_files: true` to preserve them.
  Associated DB records (artifacts, stage_executions, messages) are
  cascade-deleted by the database foreign key constraints.
  """
  def delete_item_with_files(%Item{} = item, opts \\ []) do
    keep_files = Keyword.get(opts, :keep_files, false)

    unless keep_files do
      path = item.archive_path || item.bootstrap_path

      if path && File.dir?(path) do
        File.rm_rf!(path)
      end
    end

    case Repo.delete(item) do
      {:ok, deleted} ->
        publish_deleted(deleted)
        :ok

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp publish_deleted(%Item{id: id, slug: slug}) do
    Cham.EventBus.publish("item:deleted", %ItemDeleted{item_id: id, slug: slug})
  end

  def list_stage_executions(item_id) do
    Cham.JobTracking.StageExecution
    |> where([s], s.item_id == ^item_id)
    |> order_by([s], asc: s.started_at)
    |> Repo.all()
  end

  def list_items(filters \\ []) do
    filters
    |> list_items_query()
    |> Repo.all()
  end

  @doc """
  Returns `{items, total_count}` for the given filters, paginated.

  Options:
    * `:page` — 1-indexed page number (default: 1)
    * `:page_size` — page size (default: 100)
  """
  def list_items_paginated(filters \\ [], opts \\ []) do
    page = max(Keyword.get(opts, :page, 1), 1)
    page_size = max(Keyword.get(opts, :page_size, 100), 1)
    offset = (page - 1) * page_size

    base_query = list_items_query(filters)
    total_count = Repo.aggregate(base_query, :count, :id)

    items =
      base_query
      |> limit(^page_size)
      |> offset(^offset)
      |> Repo.all()

    {items, total_count}
  end

  defp list_items_query(filters) do
    include_subscribed_feeds = Keyword.get(filters, :include_subscribed_feeds, false)
    include_backfill_seen = Keyword.get(filters, :include_backfill_seen, false)

    remaining_filters =
      filters
      |> Keyword.delete(:include_subscribed_feeds)
      |> Keyword.delete(:include_backfill_seen)

    base =
      Item
      |> apply_filters(remaining_filters)
      |> order_by([i], desc: i.inserted_at)

    base =
      if include_backfill_seen do
        base
      else
        from i in base,
          where: fragment("COALESCE(?->>'backfill_seen', 'false')", i.metadata) != "true"
      end

    if include_subscribed_feeds do
      base
    else
      from i in base,
        left_join: s in Cham.Subscriptions.Subscription,
        on: s.source_url == i.url,
        where: i.content_type != "feed" or is_nil(s.id)
    end
  end

  defp apply_filters(query, []), do: query

  defp apply_filters(query, [{:status, status} | rest]) do
    query
    |> where([i], i.status == ^status)
    |> apply_filters(rest)
  end

  defp apply_filters(query, [{:content_type, content_type} | rest]) do
    query
    |> where([i], i.content_type == ^content_type)
    |> apply_filters(rest)
  end

  defp apply_filters(query, [{:tag, tag} | rest]) do
    query
    |> where([i], ^tag in i.tags)
    |> apply_filters(rest)
  end

  defp apply_filters(query, [{:search, term} | rest]) when is_binary(term) do
    trimmed = String.trim(term)

    if trimmed == "" do
      apply_filters(query, rest)
    else
      like = "%" <> escape_like(trimmed) <> "%"

      query
      |> where(
        [i],
        ilike(i.title, ^like) or ilike(i.url, ^like) or
          ilike(fragment("COALESCE(?->>'excerpt', '')", i.metadata), ^like)
      )
      |> apply_filters(rest)
    end
  end

  defp apply_filters(query, [_ | rest]), do: apply_filters(query, rest)

  defp escape_like(term) do
    term
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  def count_by_content_type do
    from(i in Item,
      left_join: s in Cham.Subscriptions.Subscription,
      on: s.source_url == i.url,
      where: not is_nil(i.content_type),
      where: i.content_type != "feed" or is_nil(s.id),
      where: fragment("COALESCE(?->>'backfill_seen', 'false')", i.metadata) != "true",
      group_by: i.content_type,
      select: {i.content_type, count(i.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Clears tags (sets to `[]`) on every item, optionally filtered by content type.

  Returns the number of items updated.
  """
  def clear_tags(opts \\ []) do
    content_type = Keyword.get(opts, :content_type)

    query = from(i in Item, where: i.tags != ^[])

    query =
      if content_type do
        where(query, [i], i.content_type == ^content_type)
      else
        query
      end

    {count, _} = Repo.update_all(query, set: [tags: []])
    count
  end

  def count_by_tag do
    from(i in Item,
      cross_join: t in fragment("unnest(?)", i.tags),
      group_by: fragment("?", t),
      select: {fragment("?", t), count(i.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Total visible item count (matches the default `list_items_query/1` filters:
  excludes backfill_seen items and feed items that have a matching subscription).
  """
  def count_visible_items do
    [] |> list_items_query() |> Repo.aggregate(:count, :id)
  end

  def list_in_progress_items do
    statuses = ["bootstrapping", "processing", "failed"]

    Item
    |> where([i], i.status in ^statuses)
    |> order_by([i], desc: i.inserted_at)
    |> Repo.all()
  end

  def read_artifact_content(%Item{} = item, %Artifact{} = artifact) do
    item_dir = item.archive_path || item.bootstrap_path
    first_filename = List.first(artifact.filenames)
    file_path = Path.join([item_dir, artifact.path, first_filename])

    case File.read(file_path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Read the primary article markdown for an item, honoring the
  `display.content_order` config (default `["cleaned_content", "content"]`).
  For each type, derived artifacts are preferred over original.
  """
  def read_primary_markdown(%Item{} = item) do
    cond do
      item.content_type != "article" ->
        {:error, :not_found}

      item.status not in ["complete", "incomplete"] ->
        {:error, :not_ready}

      true ->
        artifacts = list_artifacts(item.id)
        do_read_primary_markdown(item, artifacts, content_order())
    end
  end

  defp do_read_primary_markdown(_item, _artifacts, []), do: {:error, :not_found}

  defp do_read_primary_markdown(item, artifacts, [type | rest]) do
    case find_and_read(item, artifacts, type, "derived") do
      {:ok, body} ->
        {:ok, body}

      :miss ->
        case find_and_read(item, artifacts, type, "original") do
          {:ok, body} -> {:ok, body}
          :miss -> do_read_primary_markdown(item, artifacts, rest)
        end
    end
  end

  defp find_and_read(item, artifacts, type, origin) do
    artifact =
      Enum.find(artifacts, fn a ->
        a.labels["type"] == type and a.labels["origin"] == origin and
          a.status == "produced"
      end)

    case artifact && read_artifact_content(item, artifact) do
      {:ok, body} -> {:ok, body}
      _ -> :miss
    end
  end

  defp content_order do
    case Cham.Config.Manager.read_all("display") do
      {:ok, %{content_order: s}} when is_binary(s) and s != "" ->
        s |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

      _ ->
        ["cleaned_content", "content"]
    end
  end

  def create_artifact(attrs) do
    %Artifact{}
    |> Artifact.changeset(attrs)
    |> Repo.insert()
  end

  def list_artifacts(item_id) do
    Artifact
    |> where([a], a.item_id == ^item_id)
    |> Repo.all()
  end

  @doc """
  Returns a URL to the preferred thumbnail for an item, or `nil` if none
  is available. Providers are tried in the order configured under
  `display.thumbnail_provider_order`.
  """
  def best_thumbnail_url(%Item{} = item), do: display_cache(item).thumbnail
  def best_thumbnail_url(_), do: nil

  @doc """
  Returns the preferred display title: consults title-override artifacts in
  the order configured under `display.title_provider_order`, and falls back
  to the item's own title if no override is present.
  """
  def best_title(%Item{} = item), do: display_cache(item).title
  def best_title(_), do: nil

  defp display_cache(%Item{} = item) do
    Cham.Items.Cache.fetch(item.id, fn ->
      %{title: compute_title(item), thumbnail: compute_thumbnail_url(item)}
    end)
  end

  defp compute_thumbnail_url(%Item{} = item) do
    order = provider_order("thumbnail_provider_order", ["ffmpeg"])
    thumb_artifacts = item_id_thumbnail_artifacts(item.id)

    artifact =
      Enum.find_value(order, fn provider ->
        Enum.find(thumb_artifacts, fn a ->
          (a.labels || %{})["provider"] == provider
        end)
      end)

    artifact = artifact || List.first(thumb_artifacts)

    if artifact do
      filename = artifact.filenames |> List.first() |> Path.basename()
      "/api/v1/items/#{item.id}/files/#{filename}"
    end
  end

  defp compute_title(%Item{} = item) do
    order = provider_order("title_provider_order", ["clean_title"])
    override_artifacts = item_id_title_override_artifacts(item.id)

    override =
      Enum.find_value(order, fn provider ->
        Enum.find(override_artifacts, fn a ->
          (a.labels || %{})["provider"] == provider
        end)
      end)

    case override do
      nil ->
        item.title

      artifact ->
        case read_artifact_content(item, artifact) do
          {:ok, content} -> String.trim(content)
          _ -> item.title
        end
    end
  end

  defp item_id_thumbnail_artifacts(item_id) do
    Repo.all(
      from a in Artifact,
        where: a.item_id == ^item_id,
        where:
          fragment("?->>'type'", a.labels) == "thumbnail" and
            fragment("?->>'origin'", a.labels) == "derived",
        where: a.status == "produced"
    )
  end

  defp item_id_title_override_artifacts(item_id) do
    Repo.all(
      from a in Artifact,
        where: a.item_id == ^item_id,
        where: fragment("?->>'type'", a.labels) == "title_override",
        where: a.status == "produced"
    )
  end

  defp provider_order(key, fallback) do
    value =
      case Cham.Config.Manager.read_all("display") do
        {:ok, cfg} -> Map.get(cfg, String.to_atom(key))
        _ -> nil
      end

    case value do
      s when is_binary(s) and s != "" ->
        s |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

      _ ->
        fallback
    end
  end
end
