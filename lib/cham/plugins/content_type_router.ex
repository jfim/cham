defmodule Cham.Plugins.ContentTypeRouter do
  @behaviour Cham.Plugin

  @impl true
  def plugin_id, do: "content_type_router"

  @impl true
  def name, do: "Content Type Router"

  @impl true
  def description, do: "Routes initial downloads to format-specific labels based on content type"

  @impl true
  def config_schema, do: []

  @impl true
  def init(_context), do: {:ok, %{}}

  @impl true
  def stages(_state), do: [__MODULE__.RouteStage]
end

defmodule Cham.Plugins.ContentTypeRouter.RouteStage do
  @behaviour Cham.Stage

  @impl true
  def name, do: "Content Type Router"

  @impl true
  def description, do: "Routes downloaded content to format-specific labels based on content type"

  @impl true
  def input_matchers, do: [%{"origin" => "original", "type" => "initial_download"}]

  @impl true
  def output_labels, do: [%{"origin" => "original", "format" => "routed"}]

  @impl true
  def queue, do: :general

  @impl true
  def max_attempts, do: 3

  @impl true
  def can_process?(current_artifacts) do
    has_download =
      Enum.any?(current_artifacts, fn labels ->
        labels["origin"] == "original" and labels["type"] == "initial_download"
      end)

    if has_download do
      {:ready, input_matchers(), []}
    else
      :not_applicable
    end
  end

  @impl true
  def perform(input_artifacts, working_dir, _desired, _item_id) do
    [input] = input_artifacts
    content_type = input.labels["content_type"] || "application/octet-stream"

    effective_type = resolve_content_type(content_type, input)

    {labels, friendly_type} = route_labels(effective_type)

    # Reference the original download's files via relative path — no copying needed.
    # working_dir is e.g. .../processing/content_type_router-20260405T.../
    # input.input_path is e.g. .../processing/generic_download_url-20260405T.../
    # We produce filenames like ../generic_download_url-20260405T.../original.mp4
    ref_filenames =
      Enum.map(input.filenames, fn filename ->
        source_path = Path.join(input.input_path, filename)
        relative_path(source_path, working_dir)
      end)

    {:ok,
     %{
       artifacts: [
         %{
           labels: labels,
           filenames: ref_filenames
         }
       ],
       item_metadata: %{
         "content_type" => friendly_type
       },
       provenance: %{}
     }}
  end

  defp resolve_content_type("application/octet-stream", input) do
    [source_filename | _] = input.filenames
    source_path = Path.join(input.input_path, source_filename)

    case detect_by_magic_bytes(source_path) do
      {:ok, detected} -> detected
      :unknown -> "application/octet-stream"
    end
  end

  defp resolve_content_type(content_type, _input), do: content_type

  defp detect_by_magic_bytes(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, f} ->
        data = IO.binread(f, 512)
        File.close(f)

        case data do
          bytes when is_binary(bytes) -> match_magic(bytes)
          _ -> :unknown
        end

      _ ->
        :unknown
    end
  end

  defp match_magic(<<0x25, 0x50, 0x44, 0x46, _::binary>>), do: {:ok, "application/pdf"}
  defp match_magic(<<"<!DOCTYPE", _::binary>>), do: {:ok, "text/html"}
  defp match_magic(<<"<!doctype", _::binary>>), do: {:ok, "text/html"}
  defp match_magic(<<"<html", _::binary>>), do: {:ok, "text/html"}
  defp match_magic(<<"<HTML", _::binary>>), do: {:ok, "text/html"}

  # ID3 tag for MP3
  defp match_magic(<<"ID3", _::binary>>), do: {:ok, "audio/mpeg"}

  # ftyp box for MP4
  defp match_magic(<<_size::32, "ftyp", _::binary>>), do: {:ok, "video/mp4"}

  # OGG container
  defp match_magic(<<"OggS", _::binary>>), do: {:ok, "audio/ogg"}

  # RIFF/WAVE
  defp match_magic(<<"RIFF", _::32, "WAVE", _::binary>>), do: {:ok, "audio/wav"}

  # WebM
  defp match_magic(<<0x1A, 0x45, 0xDF, 0xA3, _::binary>>), do: {:ok, "video/webm"}

  defp match_magic(<<"<?xml", rest::binary>>) do
    window = rest |> binary_part(0, min(byte_size(rest), 512))

    cond do
      String.contains?(window, "<rss") -> {:ok, "application/rss+xml"}
      String.contains?(window, "<feed") -> {:ok, "application/atom+xml"}
      true -> :unknown
    end
  end

  defp match_magic(<<"<rss", _::binary>>), do: {:ok, "application/rss+xml"}
  defp match_magic(<<"<feed", _::binary>>), do: {:ok, "application/atom+xml"}

  defp match_magic(_), do: :unknown

  defp route_labels("text/html") do
    {%{"origin" => "original", "format" => "text", "type" => "article"}, "article"}
  end

  defp route_labels("application/pdf") do
    {%{"origin" => "original", "format" => "document", "type" => "pdf"}, "document"}
  end

  defp route_labels("video/" <> _) do
    {%{"origin" => "original", "format" => "video"}, "video"}
  end

  defp relative_path(target, from_dir) do
    target_parts = Path.expand(target) |> Path.split()
    from_parts = Path.expand(from_dir) |> Path.split()

    # Find common prefix length
    common =
      Enum.zip(target_parts, from_parts)
      |> Enum.take_while(fn {a, b} -> a == b end)
      |> length()

    ups = length(from_parts) - common
    remaining = Enum.drop(target_parts, common)

    (List.duplicate("..", ups) ++ remaining)
    |> Path.join()
  end

  defp route_labels("audio/" <> _) do
    {%{"origin" => "original", "format" => "audio"}, "audio"}
  end

  defp route_labels("application/rss+xml") do
    {%{"origin" => "original", "format" => "feed"}, "feed"}
  end

  defp route_labels("application/atom+xml") do
    {%{"origin" => "original", "format" => "feed"}, "feed"}
  end

  defp route_labels("text/xml"), do: route_labels("application/rss+xml")
  defp route_labels("application/xml"), do: route_labels("application/rss+xml")

  defp route_labels(_) do
    {%{"origin" => "original", "format" => "unknown"}, "unknown"}
  end
end
