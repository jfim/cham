defmodule Cham.Plugins.ExtractPdf do
  @behaviour Cham.Plugin

  @impl true
  def plugin_id, do: "extract_pdf"

  @impl true
  def name, do: "PDF Text Extractor"

  @impl true
  def description, do: "Extracts text content from PDF documents using pypdf"

  @impl true
  def config_schema, do: []

  @impl true
  def init(_context), do: {:ok, %{}}

  @impl true
  def stages(_state), do: [__MODULE__.ExtractStage]
end

defmodule Cham.Plugins.ExtractPdf.ExtractStage do
  @behaviour Cham.Stage

  @impl true
  def name, do: "Extract PDF Text"

  @impl true
  def description, do: "Extracts text from PDF documents using pypdf"

  @impl true
  def input_matchers,
    do: [%{"origin" => "original", "format" => "document", "type" => "pdf"}]

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
    has_pdf =
      Enum.any?(current_artifacts, fn labels ->
        labels["origin"] == "original" and
          labels["format"] == "document" and
          labels["type"] == "pdf"
      end)

    if has_pdf do
      {:ready, input_matchers(), []}
    else
      :not_applicable
    end
  end

  @impl true
  def perform(input_artifacts, working_dir, _desired, _item_id) do
    [input] = input_artifacts
    [pdf_filename | _] = input.filenames
    pdf_path = Path.join(input.input_path, pdf_filename)

    case Cham.ScriptRunner.run_script_sync("extract_pdf", [pdf_path, working_dir],
           timeout: 120_000
         ) do
      {:ok, output, _stderr, 0} ->
        item_metadata = parse_metadata(output)

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
           item_metadata: item_metadata,
           provenance: %{"tool" => "pypdf"}
         }}

      {:ok, output, _stderr, exit_code} ->
        {:error, "extract_pdf script failed (exit #{exit_code}): #{String.trim(output)}"}

      {:error, :timeout, _output, _stderr} ->
        {:error, "extract_pdf script timed out"}
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
