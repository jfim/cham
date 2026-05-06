defmodule Cham.Plugins.ExtractPlaintext do
  @behaviour Cham.Plugin

  @impl true
  def plugin_id, do: "extract_plaintext"

  @impl true
  def name, do: "Plaintext Extractor"

  @impl true
  def description, do: "Passes plaintext content through verbatim as markdown"

  @impl true
  def config_schema, do: []

  @impl true
  def init(_context), do: {:ok, %{}}

  @impl true
  def stages(_state), do: [__MODULE__.ExtractStage]
end

defmodule Cham.Plugins.ExtractPlaintext.ExtractStage do
  @behaviour Cham.Stage

  @impl true
  def name, do: "Extract Plaintext"

  @impl true
  def description, do: "Copies plaintext content verbatim into content.md"

  @impl true
  def input_matchers,
    do: [%{"origin" => "original", "format" => "text", "type" => "plaintext"}]

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
    has_plaintext =
      Enum.any?(current_artifacts, fn labels ->
        labels["origin"] == "original" and
          labels["format"] == "text" and
          labels["type"] == "plaintext"
      end)

    if has_plaintext do
      {:ready, input_matchers(), []}
    else
      :not_applicable
    end
  end

  @impl true
  def perform(input_artifacts, working_dir, _desired, _item_id) do
    [input] = input_artifacts

    ref_filenames =
      Enum.map(input.filenames, fn filename ->
        source_path = Path.join(input.input_path, filename)
        relative_path(source_path, working_dir)
      end)

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
           filenames: ref_filenames
         }
       ],
       item_metadata: %{},
       provenance: %{"tool" => "passthrough"}
     }}
  end

  defp relative_path(target, from_dir) do
    target_parts = Path.expand(target) |> Path.split()
    from_parts = Path.expand(from_dir) |> Path.split()

    common =
      Enum.zip(target_parts, from_parts)
      |> Enum.take_while(fn {a, b} -> a == b end)
      |> length()

    ups = length(from_parts) - common
    remaining = Enum.drop(target_parts, common)

    (List.duplicate("..", ups) ++ remaining)
    |> Path.join()
  end
end
