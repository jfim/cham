defmodule Cham.Plugins.ExtractThumbnail do
  @behaviour Cham.Plugin

  @impl true
  def plugin_id, do: "extract_thumbnail"

  @impl true
  def name, do: "Thumbnail Extractor"

  @impl true
  def description do
    "Extracts a single-frame JPEG thumbnail from a video file using ffmpeg. " <>
      "Produces one derived artifact tagged provider:ffmpeg so additional " <>
      "out-of-tree thumbnail providers can coexist via their own plugins."
  end

  @impl true
  def config_schema do
    [
      %{
        key: :seek_seconds,
        type: :integer,
        default: 10,
        description: "How many seconds into the video to grab the frame",
        required: false,
        options: nil
      },
      %{
        key: :width,
        type: :integer,
        default: 640,
        description: "Maximum thumbnail width in pixels (aspect-preserving)",
        required: false,
        options: nil
      }
    ]
  end

  @impl true
  def init(_context) do
    Cham.Config.Manager.register("plugins.extract_thumbnail", config_schema())
    {:ok, %{}}
  end

  @impl true
  def stages(_state), do: [__MODULE__.Stage]
end

defmodule Cham.Plugins.ExtractThumbnail.Stage do
  @behaviour Cham.Stage

  @default_seek 10
  @default_width 640

  @impl true
  def name, do: "Extract Thumbnail"

  @impl true
  def description, do: "ffmpeg-based thumbnail extraction (single JPEG frame)"

  @impl true
  def input_matchers, do: [%{"origin" => "original", "format" => "video"}]

  @impl true
  def output_labels do
    [
      %{
        "origin" => "derived",
        "type" => "thumbnail",
        "provider" => "ffmpeg",
        "content_type" => "image/jpeg"
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
    out_path = Path.join(working_dir, "thumb.jpg")

    File.mkdir_p!(working_dir)

    cfg = load_config()
    seek = Map.get(cfg, :seek_seconds, @default_seek)
    width = Map.get(cfg, :width, @default_width)

    args = [
      "-y",
      "-loglevel",
      "error",
      "-ss",
      Integer.to_string(seek),
      "-i",
      video_path,
      "-frames:v",
      "1",
      "-vf",
      "scale='min(#{width},iw)':-2",
      "-q:v",
      "3",
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
                 "type" => "thumbnail",
                 "provider" => "ffmpeg",
                 "content_type" => "image/jpeg"
               },
               filenames: ["thumb.jpg"]
             }
           ],
           item_metadata: %{},
           provenance: %{"tool" => "ffmpeg", "seek_seconds" => seek, "width" => width}
         }}

      {output, exit_code} ->
        {:error, "extract_thumbnail: ffmpeg exited #{exit_code}: #{String.trim(output)}"}
    end
  rescue
    e in ErlangError ->
      case e.original do
        :enoent -> {:error, "extract_thumbnail: ffmpeg not found on PATH"}
        other -> {:error, "extract_thumbnail: #{inspect(other)}"}
      end
  end

  defp load_config do
    try do
      case Cham.Config.Manager.read_all("plugins.extract_thumbnail") do
        {:ok, cfg} when is_map(cfg) -> cfg
        _ -> %{}
      end
    rescue
      _ -> %{}
    end
  end
end
