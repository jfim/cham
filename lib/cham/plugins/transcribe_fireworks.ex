defmodule Cham.Plugins.TranscribeFireworks do
  @behaviour Cham.Plugin

  @impl true
  def plugin_id, do: "transcribe_fireworks"

  @impl true
  def name, do: "Fireworks Transcriber"

  @impl true
  def description, do: "Transcribes audio/video via Fireworks AI's whisper API (remote, GPU-free)"

  @impl true
  def config_schema do
    [
      %{
        key: :api_key,
        type: :string,
        default: nil,
        description: "Fireworks API key",
        required: true,
        options: nil
      },
      %{
        key: :model,
        type: :string,
        default: "whisper-v3-turbo",
        description: "Whisper model variant",
        required: false,
        options: ["whisper-v3", "whisper-v3-turbo"]
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
        key: :prompt,
        type: :string,
        default: nil,
        description: "Optional prompt to bias the model (custom vocab, style)",
        required: false,
        options: nil
      },
      %{
        key: :temperature,
        type: :string,
        default: "0,0.2,0.4,0.6,0.8,1.0",
        description:
          "Sampling temperature; comma-separated list enables fallback decoding on hallucination/low-confidence segments",
        required: false,
        options: nil
      }
    ]
  end

  @impl true
  def init(_context) do
    Cham.Config.Manager.register("plugins.transcribe_fireworks", config_schema())
    {:ok, %{}}
  end

  @impl true
  def stages(_state), do: [__MODULE__.TranscribeStage]
end

defmodule Cham.Plugins.TranscribeFireworks.TranscribeStage do
  @behaviour Cham.Stage

  require Logger

  @compression_ratio_threshold 2.4
  @avg_logprob_threshold -1.0
  @bad_segment_ratio_threshold 0.2

  @impl true
  def name, do: "Transcribe Audio (Fireworks)"

  @impl true
  def description, do: "Uploads media to Fireworks audio API and writes a timestamped transcript"

  @impl true
  def input_matchers do
    [
      %{"origin" => "original", "format" => "audio"},
      %{"origin" => "derived", "format" => "audio"}
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
  def queue, do: :network

  @impl true
  def max_attempts, do: 3

  @impl true
  def can_process?(current_artifacts) do
    has_audio =
      Enum.any?(current_artifacts, fn labels -> labels["format"] == "audio" end)

    if has_audio, do: {:ready, input_matchers(), []}, else: :not_applicable
  end

  @endpoints %{
    "whisper-v3" => "https://audio-prod.api.fireworks.ai/v1/audio/transcriptions",
    "whisper-v3-turbo" => "https://audio-turbo.api.fireworks.ai/v1/audio/transcriptions"
  }

  @impl true
  def perform(input_artifacts, working_dir, _desired, _item_id) do
    config = Cham.Plugin.Config.read("transcribe_fireworks")

    api_key = Map.get(config, :api_key)
    model = Map.get(config, :model, "whisper-v3-turbo")
    language = Map.get(config, :language)
    prompt = Map.get(config, :prompt)
    temperature = Map.get(config, :temperature, "0,0.2,0.4,0.6,0.8,1.0")

    cond do
      api_key in [nil, ""] ->
        {:error, "transcribe_fireworks: api_key not configured"}

      not Map.has_key?(@endpoints, model) ->
        {:error, "transcribe_fireworks: unknown model #{inspect(model)}"}

      true ->
        [input | _] = input_artifacts
        [media_filename | _] = input.filenames
        media_path = Path.join(input.input_path, media_filename)

        do_transcribe(media_path, working_dir, api_key, model, language, prompt, temperature)
    end
  end

  defp do_transcribe(media_path, working_dir, api_key, model, language, prompt, temperature) do
    file_part =
      {File.read!(media_path),
       filename: Path.basename(media_path), content_type: MIME.from_path(media_path)}

    parts =
      [
        file: file_part,
        model: model,
        response_format: "verbose_json",
        "timestamp_granularities[]": "segment"
      ] ++
        if(language, do: [language: language], else: []) ++
        if(prompt, do: [prompt: prompt], else: []) ++
        if(temperature not in [nil, ""], do: [temperature: temperature], else: [])

    url = Map.fetch!(@endpoints, model)

    case Req.post(url,
           form_multipart: parts,
           headers: [{"authorization", "Bearer #{api_key}"}],
           receive_timeout: 1_800_000,
           connect_options: [timeout: 60_000]
         ) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        write_transcript(body, working_dir, model)

      {:ok, %{status: status, body: body}} ->
        {:error, "transcribe_fireworks: API returned #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, "transcribe_fireworks: HTTP failure: #{inspect(reason)}"}
    end
  end

  defp write_transcript(body, working_dir, model) do
    segments = Map.get(body, "segments", [])
    full_text = Map.get(body, "text", "")
    duration = Map.get(body, "duration", 0)
    language = Map.get(body, "language", "")

    transcript =
      cond do
        segments != [] ->
          Enum.map_join(segments, "\n", fn seg ->
            ts = format_timestamp(Map.get(seg, "start", 0))
            text = seg |> Map.get("text", "") |> String.trim()
            "[#{ts}] #{text}"
          end)

        full_text != "" ->
          full_text

        true ->
          ""
      end

    File.mkdir_p!(working_dir)
    File.write!(Path.join(working_dir, "transcript.md"), transcript)

    quality = segment_quality(segments)
    maybe_warn_quality(quality)

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
       item_metadata: %{"language" => language, "duration" => trunc(duration)},
       provenance:
         Map.merge(%{"model" => model, "tool" => "fireworks-audio"}, quality)
     }}
  end

  defp segment_quality([]), do: %{"segment_count" => 0, "bad_segment_count" => 0}

  defp segment_quality(segments) do
    bad =
      Enum.count(segments, fn seg ->
        cr = Map.get(seg, "compression_ratio")
        lp = Map.get(seg, "avg_logprob")

        (is_number(cr) and cr > @compression_ratio_threshold) or
          (is_number(lp) and lp < @avg_logprob_threshold)
      end)

    total = length(segments)

    %{
      "segment_count" => total,
      "bad_segment_count" => bad,
      "bad_segment_ratio" => if(total > 0, do: bad / total, else: 0.0),
      "quality_warning" =>
        total > 0 and bad / total >= @bad_segment_ratio_threshold
    }
  end

  defp maybe_warn_quality(%{"quality_warning" => true} = q) do
    Logger.warning(
      "transcribe_fireworks: likely hallucination — #{q["bad_segment_count"]}/#{q["segment_count"]} segments exceeded compression_ratio/avg_logprob thresholds"
    )
  end

  defp maybe_warn_quality(_), do: :ok

  defp format_timestamp(seconds) when is_number(seconds) do
    h = trunc(seconds) |> div(3600)
    m = trunc(seconds) |> rem(3600) |> div(60)
    s = trunc(seconds) |> rem(60)
    if h > 0, do: :io_lib.format("~B:~2..0B:~2..0B", [h, m, s]) |> IO.iodata_to_binary(),
       else: :io_lib.format("~B:~2..0B", [m, s]) |> IO.iodata_to_binary()
  end

  defp format_timestamp(_), do: "0:00"
end
