defmodule Cham.Plugins.AlambicCleanMarkdown do
  @behaviour Cham.Plugin

  @impl true
  def plugin_id, do: "alambic_clean_markdown"

  @impl true
  def name, do: "Alambic Clean Markdown"

  @impl true
  def description,
    do:
      "Cleans extracted article markdown via the Alambic /api/clean endpoint. " <>
        "Emits a 'cleaned_content' artifact — add 'cleaned_content' to " <>
        "[desired_artifacts] article in cham.toml for the stage to run."

  @impl true
  def default_enabled?, do: false

  @impl true
  def config_schema do
    [
      %{
        key: :url,
        type: :string,
        default: nil,
        description: "Base URL of the Alambic service (e.g. http://alambic:4000)",
        required: true,
        options: nil
      },
      %{
        key: :receive_timeout_ms,
        type: :integer,
        default: 300_000,
        description: "HTTP receive timeout in milliseconds (default 5 minutes)",
        required: false,
        options: nil
      }
    ]
  end

  @impl true
  def init(_context) do
    Cham.Config.Manager.register("plugins.alambic_clean_markdown", config_schema())
    {:ok, %{}}
  end

  @impl true
  def stages(_state), do: [__MODULE__.CleanStage]
end

defmodule Cham.Plugins.AlambicCleanMarkdown.CleanStage do
  @behaviour Cham.Stage

  @impl true
  def name, do: "Clean Markdown (Alambic)"

  @impl true
  def description,
    do: "Sends extracted article markdown to Alambic /api/clean and writes the cleaned version"

  @impl true
  def input_matchers,
    do: [
      %{
        "origin" => "original",
        "format" => "text",
        "type" => "content",
        "content_type" => "text/markdown"
      }
    ]

  @impl true
  def output_labels,
    do: [
      %{
        "origin" => "derived",
        "format" => "text",
        "type" => "cleaned_content",
        "content_type" => "text/markdown"
      }
    ]

  @impl true
  def queue, do: :network

  @impl true
  def max_attempts, do: 3

  @impl true
  def can_process?(current_artifacts) do
    has_input =
      Enum.any?(current_artifacts, fn labels ->
        labels["origin"] == "original" and
          labels["format"] == "text" and
          labels["type"] == "content" and
          labels["content_type"] == "text/markdown"
      end)

    if has_input, do: {:ready, input_matchers(), []}, else: :not_applicable
  end

  @impl true
  def perform(input_artifacts, working_dir, _desired, item_id) do
    config = Cham.Plugin.Config.read("alambic_clean_markdown")
    url = Map.get(config, :url)
    timeout = Map.get(config, :receive_timeout_ms, 300_000)

    if url in [nil, ""] do
      {:error, "alambic_clean_markdown: url not configured"}
    else
      [input | _] = input_artifacts
      [filename | _] = input.filenames
      text = File.read!(Path.join(input.input_path, filename))

      do_clean(url, item_id, text, timeout, working_dir)
    end
  end

  defp do_clean(base_url, item_id, text, timeout, working_dir) do
    endpoint = String.trim_trailing(base_url, "/") <> "/api/clean"

    case Req.post(endpoint,
           json: %{item_id: item_id, text: text},
           receive_timeout: timeout,
           connect_options: [timeout: 30_000]
         ) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        write_cleaned(body, working_dir)

      {:ok, %{status: 503, body: body}} ->
        {:snooze, 60_000, "alambic_clean_markdown: service unavailable: #{inspect(body)}"}

      {:ok, %{status: status, body: body}} ->
        {:error, "alambic_clean_markdown: API returned #{status}: #{inspect(body)}"}

      {:error, %{reason: :econnrefused}} ->
        {:snooze, 60_000, "alambic_clean_markdown: connection refused"}

      {:error, %{reason: :timeout}} ->
        {:snooze, 60_000, "alambic_clean_markdown: request timed out"}

      {:error, reason} ->
        {:error, "alambic_clean_markdown: HTTP failure: #{inspect(reason)}"}
    end
  end

  defp write_cleaned(body, working_dir) do
    cleaned = Map.get(body, "cleaned_text", "")

    File.mkdir_p!(working_dir)
    File.write!(Path.join(working_dir, "cleaned_content.md"), cleaned)

    provenance =
      %{"tool" => "alambic"}
      |> maybe_put("source", Map.get(body, "source"))
      |> maybe_put("model_version", Map.get(body, "model_version"))
      |> maybe_put("confidence", Map.get(body, "confidence"))

    {:ok,
     %{
       artifacts: [
         %{
           labels: %{
             "origin" => "derived",
             "format" => "text",
             "type" => "cleaned_content",
             "content_type" => "text/markdown"
           },
           filenames: ["cleaned_content.md"]
         }
       ],
       item_metadata: %{},
       provenance: provenance
     }}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
