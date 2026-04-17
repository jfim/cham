defmodule Cham.Plugins.ExtractFeedItems do
  @behaviour Cham.Plugin

  @impl true
  def plugin_id, do: "extract_feed_items"

  @impl true
  def name, do: "Extract Feed Items"

  @impl true
  def description,
    do: "Parses RSS/Atom feeds and writes a metadata artifact with entry previews"

  @impl true
  def config_schema, do: []

  @impl true
  def init(_context), do: {:ok, %{}}

  @impl true
  def stages(_state), do: [__MODULE__.Stage]
end

defmodule Cham.Plugins.ExtractFeedItems.Stage do
  @behaviour Cham.Stage

  alias Cham.Subscriptions.RssParser

  @impl true
  def name, do: "Extract Feed Items"

  @impl true
  def description, do: "Parses feed XML into a feed_metadata artifact"

  @impl true
  def input_matchers, do: [%{"origin" => "original", "format" => "feed"}]

  @impl true
  def output_labels, do: [%{"origin" => "derived", "type" => "feed_metadata"}]

  @impl true
  def queue, do: :general

  @impl true
  def max_attempts, do: 3

  @impl true
  def can_process?(artifacts) do
    has_feed =
      Enum.any?(artifacts, fn l ->
        l["origin"] == "original" and l["format"] == "feed"
      end)

    has_metadata =
      Enum.any?(artifacts, fn l ->
        l["origin"] == "derived" and l["type"] == "feed_metadata"
      end)

    cond do
      has_metadata -> :not_applicable
      has_feed -> {:ready, input_matchers(), []}
      true -> :not_applicable
    end
  end

  @impl true
  def perform(input_artifacts, working_dir, _desired, _item_id) do
    [input] = input_artifacts
    [file | _] = input.filenames
    xml = File.read!(Path.join(input.input_path, file))

    case RssParser.parse(xml) do
      {:ok, parsed} ->
        metadata = %{
          "title" => parsed.title,
          "description" => parsed.description,
          "subscription_backend" => "cham_rss",
          "entries" =>
            parsed.entries
            |> Enum.take(20)
            |> Enum.map(fn e ->
              %{
                "source_item_id" => e.source_item_id,
                "url" => e.url,
                "title" => e.title,
                "timestamp" =>
                  case e.timestamp do
                    nil -> nil
                    dt -> DateTime.to_iso8601(dt)
                  end
              }
            end)
        }

        out_name = "feed_metadata.json"
        File.mkdir_p!(working_dir)
        File.write!(Path.join(working_dir, out_name), Jason.encode!(metadata, pretty: true))

        {:ok,
         %{
           artifacts: [
             %{
               labels: %{"origin" => "derived", "type" => "feed_metadata"},
               filenames: [out_name]
             }
           ],
           item_metadata: %{"content_type" => "feed", "title" => parsed.title},
           provenance: %{}
         }}

      {:error, reason} ->
        {:error, {:feed_parse_failed, reason}}
    end
  end
end
