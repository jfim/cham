defmodule Cham.Archive.MetadataManager do
  @moduledoc """
  Reads and merges artifact.json files across stage processing directories.
  Provides metadata query helpers.
  """

  alias Cham.Archive.ArchiveManager

  @doc """
  Reads and parses an artifact.json file from a stage directory.
  """
  def read_artifact_json(stage_dir) do
    path = Path.join(stage_dir, "artifact.json")

    if File.exists?(path) do
      case File.read!(path) |> Jason.decode() do
        {:ok, data} -> {:ok, data}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :not_found}
    end
  end

  @doc """
  Merges artifacts and metadata from all stage directories for an item.
  Metadata uses latest-timestamp-wins semantics.
  """
  def merge_item_state(item_dir) do
    stage_dirs = ArchiveManager.list_stage_dirs(item_dir)

    stage_data =
      stage_dirs
      |> Enum.map(fn dir -> {dir, read_artifact_json(dir)} end)
      |> Enum.filter(fn {_dir, result} -> match?({:ok, _}, result) end)
      |> Enum.map(fn {dir, {:ok, data}} -> {dir, data} end)
      |> Enum.sort_by(fn {_dir, data} ->
        get_in(data, ["stage", "end_ts"]) || 0
      end)

    artifacts =
      Enum.flat_map(stage_data, fn {dir, data} ->
        (data["artifacts"] || [])
        |> Enum.map(fn artifact ->
          Map.put(artifact, "stage_dir", Path.basename(dir))
        end)
      end)

    metadata =
      Enum.reduce(stage_data, %{}, fn {_dir, data}, acc ->
        case data["item_metadata"] do
          nil -> acc
          meta -> Map.merge(acc, meta)
        end
      end)

    stages =
      Enum.map(stage_data, fn {dir, data} ->
        %{
          "dir" => Path.basename(dir),
          "plugin_id" => get_in(data, ["stage", "plugin_id"]),
          "start_ts" => get_in(data, ["stage", "start_ts"]),
          "end_ts" => get_in(data, ["stage", "end_ts"])
        }
      end)

    {:ok, %{artifacts: artifacts, metadata: metadata, stages: stages}}
  end

  @doc """
  Returns the most recent value for a metadata key (latest-timestamp-wins).
  """
  def get_latest(item_dir, key) do
    {:ok, state} = merge_item_state(item_dir)
    Map.get(state.metadata, key)
  end

  @doc """
  Returns all values for a metadata key across stages, keyed by plugin_id.
  """
  def get_all(item_dir, key) do
    stage_dirs = ArchiveManager.list_stage_dirs(item_dir)

    stage_dirs
    |> Enum.map(fn dir -> {dir, read_artifact_json(dir)} end)
    |> Enum.filter(fn {_dir, result} -> match?({:ok, _}, result) end)
    |> Enum.map(fn {dir, {:ok, data}} -> {dir, data} end)
    |> Enum.sort_by(fn {_dir, data} -> get_in(data, ["stage", "end_ts"]) || 0 end)
    |> Enum.reduce(%{}, fn {_dir, data}, acc ->
      plugin_id = get_in(data, ["stage", "plugin_id"])
      meta = data["item_metadata"] || %{}

      case Map.get(meta, key) do
        nil -> acc
        value -> Map.put(acc, plugin_id, value)
      end
    end)
  end

  @doc """
  Returns the value for a metadata key from a specific stage (by plugin_id).
  """
  def get_from(item_dir, stage_id, key) do
    stage_dirs = ArchiveManager.list_stage_dirs(item_dir)

    stage_dirs
    |> Enum.find(fn dir ->
      case read_artifact_json(dir) do
        {:ok, data} -> get_in(data, ["stage", "plugin_id"]) == stage_id
        _ -> false
      end
    end)
    |> case do
      nil ->
        nil

      dir ->
        {:ok, data} = read_artifact_json(dir)
        get_in(data, ["item_metadata", key])
    end
  end
end
