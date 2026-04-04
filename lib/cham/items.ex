defmodule Cham.Items do
  import Ecto.Query

  alias Cham.Repo
  alias Cham.Items.{Item, Artifact}

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
            {:error, :not_found}
        end
    end
  end

  def update_item(%Item{} = item, attrs) do
    item
    |> Item.update_changeset(attrs)
    |> Repo.update()
  end

  def delete_item(%Item{} = item) do
    Repo.delete(item)
  end

  def list_items(filters \\ []) do
    Item
    |> apply_filters(filters)
    |> order_by([i], desc: i.inserted_at)
    |> Repo.all()
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

  defp apply_filters(query, [_ | rest]), do: apply_filters(query, rest)

  def count_by_content_type do
    Item
    |> where([i], not is_nil(i.content_type))
    |> group_by([i], i.content_type)
    |> select([i], {i.content_type, count(i.id)})
    |> Repo.all()
    |> Map.new()
  end

  def count_by_tag do
    Item
    |> select([i], i.tags)
    |> Repo.all()
    |> List.flatten()
    |> Enum.frequencies()
  end

  def list_in_progress_items do
    statuses = ["bootstrapping", "processing", "failed", "incomplete"]

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
end
