defmodule Cham.Plugins.TranscribeWhisper do
  @behaviour Cham.Plugin

  @impl true
  def plugin_id, do: "transcribe_whisper"

  @impl true
  def name, do: "Whisper Transcriber"

  @impl true
  def description, do: "Transcribes audio/video using faster-whisper"

  @impl true
  def config_schema do
    [
      %{
        key: :model,
        type: :string,
        default: "turbo",
        description: "Whisper model name",
        required: false,
        options: nil
      },
      %{
        key: :language,
        type: :string,
        default: nil,
        description: "Language code (nil for auto-detect)",
        required: false,
        options: nil
      },
      %{
        key: :device,
        type: :string,
        default: "auto",
        description: "Device",
        required: false,
        options: ["auto", "cpu", "cuda"]
      }
    ]
  end

  @impl true
  def init(_context), do: {:ok, %{}}

  @impl true
  def stages(_state), do: [__MODULE__.TranscribeStage]
end

defmodule Cham.Plugins.TranscribeWhisper.TranscribeStage do
  @behaviour Cham.Stage

  @impl true
  def name, do: "Transcribe Audio"

  @impl true
  def description, do: "Transcribes audio/video files using faster-whisper"

  @impl true
  def input_matchers do
    [
      %{"origin" => "original", "format" => "video"},
      %{"origin" => "original", "format" => "audio"}
    ]
  end

  @impl true
  def output_labels do
    [
      %{
        "origin" => "derived",
        "format" => "text",
        "type" => "transcript",
        "content_type" => "text/markdown"
      }
    ]
  end

  @impl true
  def queue, do: :gpu

  @impl true
  def max_attempts, do: 3

  @impl true
  def can_process?(current_artifacts) do
    has_media =
      Enum.any?(current_artifacts, fn labels ->
        labels["origin"] == "original" and
          labels["format"] in ["video", "audio"]
      end)

    if has_media do
      {:ready, input_matchers(), []}
    else
      :not_applicable
    end
  end

  @impl true
  def perform(input_artifacts, working_dir, _desired, _item_id) do
    config = get_config()

    [input | _] = input_artifacts
    [media_filename | _] = input.filenames
    media_path = Path.join(input.input_path, media_filename)

    model = Map.get(config, :model, "turbo")
    language = Map.get(config, :language)
    device = Map.get(config, :device, "auto")

    args = [media_path, working_dir, "--model", model, "--device", device]
    args = if language, do: args ++ ["--language", language], else: args

    case Cham.ScriptRunner.run_script_sync("transcribe_whisper", args, timeout: 1_800_000) do
      {:ok, output, _stderr, 0} ->
        if String.contains?(output, "GPU memory") do
          {:snooze, 60_000, "Insufficient GPU memory"}
        else
          item_metadata = parse_metadata(output)

          {:ok,
           %{
             artifacts: [
               %{
                 labels: %{
                   "origin" => "derived",
                   "format" => "text",
                   "type" => "transcript",
                   "content_type" => "text/markdown"
                 },
                 filenames: ["transcript.md"]
               }
             ],
             item_metadata: item_metadata,
             provenance: %{"model" => model, "tool" => "faster-whisper"}
           }}
        end

      {:ok, output, _stderr, exit_code} ->
        if String.contains?(output, "GPU memory") do
          {:snooze, 60_000, "Insufficient GPU memory"}
        else
          {:error, "transcribe_whisper script failed (exit #{exit_code}): #{String.trim(output)}"}
        end

      {:error, :timeout, _output, _stderr} ->
        {:error, "transcribe_whisper script timed out"}
    end
  end

  defp get_config do
    case Cham.Plugin.Registry.get_plugin("transcribe_whisper") do
      {:ok, entry} ->
        defaults =
          entry.config_schema
          |> Enum.map(fn field -> {field.key, field.default} end)
          |> Map.new()

        defaults

      _ ->
        %{model: "turbo", language: nil, device: "auto"}
    end
  end

  defp parse_metadata(output) do
    output
    |> String.trim()
    |> String.split("\n")
    |> List.last()
    |> case do
      nil -> %{}
      line -> Jason.decode!(line)
    end
  rescue
    _ -> %{}
  end
end
