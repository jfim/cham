defmodule Cham.Plugins.ExtractAudio do
  @behaviour Cham.Plugin

  @impl true
  def plugin_id, do: "extract_audio"

  @impl true
  def name, do: "Audio Extractor"

  @impl true
  def description, do: "Demuxes the audio track from a video file using ffmpeg (opus mono)"

  @impl true
  def config_schema, do: []

  @impl true
  def init(_context), do: {:ok, %{}}

  @impl true
  def stages(_state), do: [__MODULE__.ExtractStage]
end

defmodule Cham.Plugins.ExtractAudio.ExtractStage do
  @behaviour Cham.Stage

  require Logger

  @impl true
  def name, do: "Extract Audio"

  @impl true
  def description, do: "ffmpeg-based audio demux from video (opus 32k mono)"

  @impl true
  def input_matchers, do: [%{"origin" => "original", "format" => "video"}]

  @impl true
  def output_labels do
    [
      %{
        "origin" => "derived",
        "format" => "audio",
        "type" => "extracted",
        "content_type" => "audio/ogg"
      }
    ]
  end

  @impl true
  def queue, do: :general

  @impl true
  def max_attempts, do: 3

  @impl true
  def can_process?(current_artifacts) do
    has_video =
      Enum.any?(current_artifacts, fn labels ->
        labels["origin"] == "original" and labels["format"] == "video"
      end)

    if has_video, do: {:ready, input_matchers(), []}, else: :not_applicable
  end

  @impl true
  def perform(input_artifacts, working_dir, _desired, _item_id) do
    [input | _] = input_artifacts
    [video_filename | _] = input.filenames
    video_path = Path.join(input.input_path, video_filename)
    out_path = Path.join(working_dir, "audio.opus")

    File.mkdir_p!(working_dir)

    args = [
      "-y",
      "-loglevel",
      "error",
      "-i",
      video_path,
      "-vn",
      "-ac",
      "1",
      "-c:a",
      "libopus",
      "-b:a",
      "32k",
      out_path
    ]

    case System.cmd("ffmpeg", args, stderr_to_stdout: true) do
      {_, 0} ->
        {:ok,
         %{
           artifacts: [
             %{
               labels: %{
                 "origin" => "derived",
                 "format" => "audio",
                 "type" => "extracted",
                 "content_type" => "audio/ogg"
               },
               filenames: ["audio.opus"]
             }
           ],
           item_metadata: %{},
           provenance: %{"tool" => "ffmpeg", "codec" => "libopus", "bitrate" => "32k"}
         }}

      {output, exit_code} ->
        {:error, "extract_audio: ffmpeg exited #{exit_code}: #{String.trim(output)}"}
    end
  rescue
    e in ErlangError ->
      case e.original do
        :enoent -> {:error, "extract_audio: ffmpeg not found on PATH"}
        other -> {:error, "extract_audio: #{inspect(other)}"}
      end
  end
end
