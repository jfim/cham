defmodule Cham.Plugins.DownloadImages do
  @behaviour Cham.Plugin

  @impl true
  def plugin_id, do: "download_images"

  @impl true
  def name, do: "Download Images"

  @impl true
  def description do
    "Downloads inline article images locally and produces a derived markdown " <>
      "artifact with URLs rewritten to local paths. Makes archived articles " <>
      "self-contained against remote host outages."
  end

  @impl true
  def config_schema, do: []

  @impl true
  def init(_context), do: {:ok, %{}}

  @impl true
  def stages(_state), do: [__MODULE__.Stage]
end

defmodule Cham.Plugins.DownloadImages.Stage do
  @behaviour Cham.Stage

  @impl true
  def name, do: "Download Images"

  @impl true
  def description,
    do: "Fetches images referenced by an article's markdown and rewrites URLs locally"

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
        "type" => "content",
        "content_type" => "text/markdown",
        "provider" => "download_images"
      }
    ]

  @impl true
  def queue, do: :general

  @impl true
  def max_attempts, do: 3

  @impl true
  def can_process?(current_artifacts) do
    has_markdown =
      Enum.any?(current_artifacts, fn labels ->
        labels["origin"] == "original" and
          labels["format"] == "text" and
          labels["type"] == "content" and
          labels["content_type"] == "text/markdown"
      end)

    if has_markdown, do: {:ready, input_matchers(), []}, else: :not_applicable
  end

  @impl true
  def perform(input_artifacts, working_dir, _desired, item_id) do
    [input] = input_artifacts
    [md_filename | _] = input.filenames
    md_path = Path.join(input.input_path, md_filename)

    base_url =
      case Cham.Items.get_item!(item_id) do
        %{url: url} when is_binary(url) -> url
        _ -> ""
      end

    File.mkdir_p!(working_dir)

    case Cham.ScriptRunner.run_script_sync(
           "download_images",
           [md_path, working_dir, base_url, to_string(item_id)],
           timeout: 120_000
         ) do
      {:ok, output, _stderr, 0} ->
        summary = parse_summary(output)

        filenames =
          working_dir
          |> File.ls!()
          |> Enum.sort()

        {:ok,
         %{
           artifacts: [
             %{
               labels: %{
                 "origin" => "derived",
                 "format" => "text",
                 "type" => "content",
                 "content_type" => "text/markdown",
                 "provider" => "download_images"
               },
               filenames: filenames
             }
           ],
           item_metadata: %{},
           provenance: Map.merge(%{"tool" => "download_images"}, summary)
         }}

      {:ok, output, _stderr, exit_code} ->
        {:error, "download_images script failed (exit #{exit_code}): #{String.trim(output)}"}

      {:error, :timeout, _output, _stderr} ->
        {:error, "download_images script timed out"}
    end
  end

  defp parse_summary(output) do
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
