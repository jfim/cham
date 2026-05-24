defmodule Cham.Plugins.ExtractArticle do
  @behaviour Cham.Plugin

  @impl true
  def plugin_id, do: "extract_article"

  @impl true
  def name, do: "Article Extractor"

  @impl true
  def description, do: "Extracts article content from HTML pages using readability-lxml"

  @impl true
  def config_schema, do: []

  @impl true
  def init(_context), do: {:ok, %{}}

  @impl true
  def stages(_state), do: [__MODULE__.ExtractStage]
end

defmodule Cham.Plugins.ExtractArticle.ExtractStage do
  @behaviour Cham.Stage

  @impl true
  def name, do: "Extract Article"

  @impl true
  def description,
    do: "Extracts article text and metadata from HTML using readability-lxml + markdownify"

  @impl true
  def input_matchers,
    do: [%{"origin" => "original", "format" => "text", "type" => "article"}]

  @impl true
  def output_labels,
    do: [
      %{
        "origin" => "original",
        "format" => "text",
        "type" => "content",
        "content_type" => "text/markdown"
      }
    ]

  @impl true
  def queue, do: :general

  @impl true
  def max_attempts, do: 3

  @impl true
  def can_process?(current_artifacts) do
    has_article =
      Enum.any?(current_artifacts, fn labels ->
        labels["origin"] == "original" and
          labels["format"] == "text" and
          labels["type"] == "article"
      end)

    if has_article do
      {:ready, input_matchers(), []}
    else
      :not_applicable
    end
  end

  @impl true
  def perform(input_artifacts, working_dir, _desired, _item_id) do
    [input] = input_artifacts
    [html_filename | _] = input.filenames
    html_path = Path.join(input.input_path, html_filename)

    case Cham.ScriptRunner.run_script_sync("extract_article", [html_path, working_dir],
           timeout: 60_000
         ) do
      {:ok, output, _stderr, 0} ->
        item_metadata = parse_metadata(output)
        tool = Map.get(item_metadata, "extractor", "readability-lxml")

        {:ok,
         %{
           artifacts: [
             %{
               labels: %{
                 "origin" => "original",
                 "format" => "text",
                 "type" => "content",
                 "content_type" => "text/markdown"
               },
               filenames: ["content.md"]
             }
           ],
           item_metadata: Map.delete(item_metadata, "extractor"),
           provenance: %{"tool" => tool}
         }}

      {:ok, output, _stderr, exit_code} ->
        {:error, "extract_article script failed (exit #{exit_code}): #{String.trim(output)}"}

      {:error, :timeout, _output, _stderr} ->
        {:error, "extract_article script timed out"}
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
