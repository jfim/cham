defmodule Cham.Plugins.AutoTag do
  @behaviour Cham.Plugin

  @impl true
  def plugin_id, do: "auto_tag"

  @impl true
  def name, do: "Auto Tagger"

  @impl true
  def description, do: "LLM-based automatic tagging"

  @impl true
  def config_schema do
    [
      %{
        key: :model,
        type: :string,
        default: "llama3.1:8b",
        description: "LLM model name",
        required: false,
        options: nil
      },
      %{
        key: :max_tags,
        type: :integer,
        default: 10,
        description: "Maximum number of tags to generate",
        required: false,
        options: nil
      },
      %{
        key: :url,
        type: :string,
        default: "http://localhost:11434",
        description: "LLM API base URL",
        required: false,
        options: nil
      },
      %{
        key: :api_key,
        type: :string,
        default: nil,
        description: "LLM API key (optional)",
        required: false,
        options: nil
      },
      %{
        key: :prompt,
        type: :string,
        default:
          "Analyze the following text and generate relevant tags for categorization. Return ONLY a JSON array of lowercase, hyphenated tags. No explanation, no markdown. Example: [\"machine-learning\", \"elixir\", \"web-development\"]\n\n---\n\n{{text}}",
        description:
          "Prompt template. Use {{text}} as placeholder. Must return a JSON array of strings.",
        required: false,
        options: nil
      }
    ]
  end

  @impl true
  def init(_context) do
    Cham.Config.Manager.register("plugins.auto_tag", config_schema())
    {:ok, %{}}
  end

  @impl true
  def stages(_state), do: [__MODULE__.TagStage]
end

defmodule Cham.Plugins.AutoTag.TagStage do
  @behaviour Cham.Stage

  @impl true
  def name, do: "Auto Tag"

  @impl true
  def description, do: "Generates tags for content using an LLM"

  @impl true
  def input_matchers do
    [
      %{"origin" => "original", "format" => "text", "type" => "content"},
      %{"origin" => "derived", "type" => "transcript"}
    ]
  end

  @impl true
  def output_labels do
    [%{"origin" => "derived", "type" => "tags"}]
  end

  @impl true
  def queue, do: :gpu

  @impl true
  def max_attempts, do: 3

  @impl true
  def can_process?(current_artifacts) do
    has_text_content =
      Enum.any?(current_artifacts, fn labels ->
        labels["origin"] == "original" and
          labels["format"] == "text" and
          labels["type"] == "content"
      end)

    has_transcript =
      Enum.any?(current_artifacts, fn labels ->
        labels["origin"] == "derived" and
          labels["type"] == "transcript"
      end)

    if has_text_content or has_transcript do
      {:ready, input_matchers(), []}
    else
      :not_applicable
    end
  end

  @impl true
  def perform(input_artifacts, working_dir, _desired, _item_id) do
    config = get_config()
    model = Map.get(config, :model, "llama3.1:8b")
    max_tags = Map.get(config, :max_tags, 10)

    [input | _] = input_artifacts
    [filename | _] = input.filenames
    text_path = Path.join(input.input_path, filename)

    case File.read(text_path) do
      {:ok, text} ->
        # Truncate to ~32k chars
        truncated = String.slice(text, 0, 32_000)

        prompt_template =
          Map.get(
            config,
            :prompt,
            "Analyze the following text and generate relevant tags for categorization. Return ONLY a JSON array of lowercase, hyphenated tags. No explanation, no markdown. Example: [\"machine-learning\", \"elixir\", \"web-development\"]\n\n---\n\n{{text}}"
          )

        prompt = String.replace(prompt_template, "{{text}}", truncated)

        llm_opts = [model: model, url: config[:url], api_key: config[:api_key]]

        case Cham.LLM.Provider.generate(Cham.LLM.Providers.OpenAI, prompt, llm_opts) do
          {:ok, response} ->
            tags = parse_tags(response, max_tags)
            output_path = Path.join(working_dir, "tags.json")
            File.write!(output_path, Jason.encode!(tags))

            {:ok,
             %{
               artifacts: [
                 %{
                   labels: %{"origin" => "derived", "type" => "tags"},
                   filenames: ["tags.json"]
                 }
               ],
               item_metadata: %{"tags" => tags},
               provenance: %{"model" => model}
             }}

          {:error, reason} ->
            reason_str = to_string(reason)

            if String.contains?(reason_str, "connection refused") or
                 String.contains?(reason_str, "ECONNREFUSED") do
              {:snooze, 30_000, "LLM not available: #{reason_str}"}
            else
              {:error, reason_str}
            end
        end

      {:error, reason} ->
        {:error, "Failed to read input file #{text_path}: #{inspect(reason)}"}
    end
  end

  @doc """
  Parses an LLM response into a list of normalized tags.

  Strips markdown code block wrappers, decodes JSON, filters to strings,
  downcases, and enforces max_tags limit.
  """
  def parse_tags(response, max_tags) do
    response
    |> strip_code_block()
    |> Jason.decode()
    |> case do
      {:ok, list} when is_list(list) ->
        list
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&String.downcase/1)
        |> Enum.take(max_tags)

      _ ->
        []
    end
  end

  defp strip_code_block(text) do
    text = String.trim(text)

    cond do
      String.starts_with?(text, "```json") ->
        text
        |> String.trim_leading("```json")
        |> String.trim_trailing("```")
        |> String.trim()

      String.starts_with?(text, "```") ->
        text
        |> String.trim_leading("```")
        |> String.trim_trailing("```")
        |> String.trim()

      true ->
        text
    end
  end

  defp get_config do
    Cham.Plugin.Config.read("auto_tag")
  end
end
