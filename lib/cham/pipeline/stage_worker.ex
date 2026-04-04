defmodule Cham.Pipeline.StageWorker do
  use Oban.Worker, max_attempts: 3

  alias Cham.Archive.{ArchiveManager, FilesystemManager}
  alias Cham.Items
  alias Cham.Pipeline.Events.{StageStarted, StageCompleted, StageFailed, StageSnoozed}

  require Logger

  @doc """
  Oban perform callback. Job args: %{"item_id" => id, "stage_module" => module_string, "plugin_id" => id}
  """
  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    item_id = args["item_id"]
    stage_module = String.to_existing_atom(args["stage_module"])
    plugin_id = args["plugin_id"]

    item = Items.get_item!(item_id)
    item_dir = resolve_item_dir(item)

    case execute_stage(stage_module, plugin_id, item, item_dir) do
      {:ok, _stage_dir} ->
        :ok

      {:error, reason} ->
        {:error, reason}

      {:snooze, duration_ms, reason} ->
        Cham.EventBus.publish("pipeline:stage_snoozed", %StageSnoozed{
          stage_id: plugin_id,
          item_id: item_id,
          duration_ms: duration_ms,
          reason: reason
        })

        {:snooze, div(duration_ms, 1000)}
    end
  end

  @doc """
  Execute a stage for an item. Creates working directory, calls stage.perform,
  writes artifact.json, records artifacts in DB, publishes events.
  Returns {:ok, stage_dir} | {:error, reason} | {:snooze, ms, reason}.
  """
  def execute_stage(stage_module, plugin_id, item, item_dir) do
    start_time = System.monotonic_time(:millisecond)
    start_ts = DateTime.utc_now() |> DateTime.to_unix()

    # Publish start event
    Cham.EventBus.publish("pipeline:stage_started", %StageStarted{
      stage_id: plugin_id,
      item_id: item.id
    })

    # Create working directory
    {:ok, stage_dir} = ArchiveManager.create_stage_dir(item_dir, plugin_id)

    # Resolve input artifacts
    input_artifacts = resolve_inputs(stage_module, item.id, item_dir)

    # Execute the stage
    case stage_module.perform(input_artifacts, stage_dir, [], item.id) do
      {:ok, result} ->
        end_ts = DateTime.utc_now() |> DateTime.to_unix()
        duration_ms = System.monotonic_time(:millisecond) - start_time

        # Write artifact.json
        write_artifact_json(stage_dir, plugin_id, start_ts, end_ts, result)

        # Record artifacts in DB
        record_artifacts(item.id, plugin_id, stage_dir, result)

        # Update item metadata
        update_item_metadata(item, result)

        # Publish completion event
        Cham.EventBus.publish("pipeline:stage_completed", %StageCompleted{
          stage_id: plugin_id,
          item_id: item.id,
          duration_ms: duration_ms,
          metadata: result[:item_metadata] || %{}
        })

        {:ok, stage_dir}

      {:error, reason} ->
        Cham.EventBus.publish("pipeline:stage_failed", %StageFailed{
          stage_id: plugin_id,
          item_id: item.id,
          error: inspect(reason)
        })

        {:error, reason}

      {:snooze, duration_ms, reason} ->
        {:snooze, duration_ms, reason}
    end
  end

  defp resolve_item_dir(item) do
    cond do
      item.archive_path -> item.archive_path
      item.bootstrap_path -> item.bootstrap_path
      true -> raise "Item #{item.id} has no archive_path or bootstrap_path"
    end
  end

  @doc """
  Resolves input artifacts for a stage by matching labels against the stage's input_matchers.
  Returns a list of maps with :labels, :filenames, and :input_path (absolute path).
  """
  def resolve_inputs(stage_module, item_id, item_dir) do
    Code.ensure_loaded(stage_module)

    if function_exported?(stage_module, :input_matchers, 0) do
      artifacts = Items.list_artifacts(item_id)

      Enum.flat_map(stage_module.input_matchers(), fn matcher ->
        artifacts
        |> Enum.filter(fn a ->
          Cham.Pipeline.LabelMatcher.matches?(a.labels, matcher) and a.status == "produced"
        end)
        |> Enum.map(fn a ->
          %{
            labels: a.labels,
            filenames: a.filenames,
            input_path: Path.join(item_dir, a.path)
          }
        end)
      end)
    else
      []
    end
  end

  defp write_artifact_json(stage_dir, plugin_id, start_ts, end_ts, result) do
    data = %{
      "stage" => %{
        "plugin_id" => plugin_id,
        "start_ts" => start_ts,
        "end_ts" => end_ts
      },
      "artifacts" =>
        Enum.map(result[:artifacts] || [], fn a ->
          %{
            "labels" => stringify_keys(a.labels),
            "filenames" => a.filenames
          }
        end),
      "item_metadata" => stringify_keys(result[:item_metadata] || %{}),
      "provenance" => stringify_keys(result[:provenance] || %{})
    }

    json = Jason.encode!(data, pretty: true)
    FilesystemManager.atomic_write(Path.join(stage_dir, "artifact.json"), json)
  end

  defp record_artifacts(item_id, plugin_id, stage_dir, result) do
    now = DateTime.utc_now()
    relative_path = "processing/#{Path.basename(stage_dir)}"

    Enum.each(result[:artifacts] || [], fn artifact ->
      Items.create_artifact(%{
        item_id: item_id,
        stage: plugin_id,
        labels: stringify_keys(artifact.labels),
        filenames: artifact.filenames,
        path: relative_path,
        status: "produced",
        started_at: now,
        ended_at: now
      })
    end)
  end

  @doc """
  Update item columns and metadata from stage results.
  Promotes title, content_type, tags to dedicated columns.
  Merges remaining keys into item.metadata JSON map.
  """
  def update_item_metadata(item, result) do
    meta = result[:item_metadata] || %{}
    string_meta = stringify_keys(meta)

    # Promote known fields to dedicated columns
    column_updates =
      %{}
      |> maybe_put(:title, string_meta["title"])
      |> maybe_put(:content_type, string_meta["content_type"])
      |> maybe_put(:tags, string_meta["tags"])

    # Merge everything else into item.metadata
    known_keys = ~w(title content_type tags)
    extra = Map.drop(string_meta, known_keys)

    metadata_update =
      if extra != %{} do
        %{metadata: Map.merge(item.metadata || %{}, extra)}
      else
        %{}
      end

    updates = Map.merge(column_updates, metadata_update)

    if updates != %{} do
      Items.update_item(item, updates)
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
