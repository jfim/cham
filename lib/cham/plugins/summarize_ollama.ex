defmodule Cham.Plugins.SummarizeOllama do
  @behaviour Cham.Plugin

  @impl true
  def plugin_id, do: "summarize_ollama"

  @impl true
  def name, do: "LLM Summarizer"

  @impl true
  def description, do: "LLM-based summarization using Ollama"

  @impl true
  def config_schema do
    [
      %{
        key: :model,
        type: :string,
        default: "llama3.1:8b",
        description: "Ollama model name",
        required: false,
        options: nil
      },
      %{
        key: :max_input_tokens,
        type: :integer,
        default: 8000,
        description: "Maximum input token estimate (chars / 4)",
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
          "Summarize the following text concisely. Focus on the key points and main ideas. Write the summary in Markdown format.\n\n---\n\n{{text}}",
        description: "Prompt template. Use {{text}} as placeholder for the input text.",
        required: false,
        options: nil
      }
    ]
  end

  @impl true
  def init(_context) do
    Cham.Config.Manager.register("plugins.summarize_ollama", config_schema())
    {:ok, %{}}
  end

  @impl true
  def stages(_state), do: [__MODULE__.SummarizeStage]
end

defmodule Cham.Plugins.SummarizeOllama.SummarizeStage do
  @behaviour Cham.Stage

  @impl true
  def name, do: "Summarize"

  @impl true
  def description, do: "Generates a summary of text content using an LLM"

  @impl true
  def input_matchers do
    [
      %{"origin" => "original", "format" => "text", "type" => "content"},
      %{"origin" => "derived", "type" => "transcript"}
    ]
  end

  @impl true
  def output_labels do
    [%{"origin" => "derived", "type" => "summary", "content_type" => "text/markdown"}]
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
    max_input_tokens = Map.get(config, :max_input_tokens, 8000)

    [input | _] = input_artifacts
    [filename | _] = input.filenames
    text_path = Path.join(input.input_path, filename)

    case File.read(text_path) do
      {:ok, text} ->
        word_count = text |> String.split(~r/\s+/, trim: true) |> length()

        if word_count < 50 do
          output_path = Path.join(working_dir, "summary.md")
          File.write!(output_path, "")

          {:ok,
           %{
             artifacts: [
               %{
                 labels: %{
                   "origin" => "derived",
                   "type" => "summary",
                   "content_type" => "text/markdown"
                 },
                 filenames: ["summary.md"]
               }
             ],
             item_metadata: %{},
             provenance: %{"skipped" => "insufficient_input", "word_count" => word_count}
           }}
        else
          summarize_with_llm(text, max_input_tokens, working_dir, config, model)
        end

      {:error, reason} ->
        {:error, "Failed to read input file #{text_path}: #{inspect(reason)}"}
    end
  end

  defp summarize_with_llm(text, max_input_tokens, working_dir, config, model) do
    max_chars = max_input_tokens * 4
    truncated = String.slice(text, 0, max_chars)

    prompt_template =
      Map.get(
        config,
        :prompt,
        "Summarize the following text concisely. Focus on the key points and main ideas. Write the summary in Markdown format.\n\n---\n\n{{text}}"
      )

    prompt = String.replace(prompt_template, "{{text}}", truncated)

    llm_opts = [model: model, url: config[:url], api_key: config[:api_key]]

    case Cham.LLM.Provider.generate(Cham.LLM.Providers.OpenAI, prompt, llm_opts) do
      {:ok, summary} ->
        output_path = Path.join(working_dir, "summary.md")
        File.write!(output_path, summary)

        {:ok,
         %{
           artifacts: [
             %{
               labels: %{
                 "origin" => "derived",
                 "type" => "summary",
                 "content_type" => "text/markdown"
               },
               filenames: ["summary.md"]
             }
           ],
           item_metadata: %{"summary_excerpt" => summary_excerpt(summary)},
           provenance: %{"model" => model}
         }}

      {:error, reason} ->
        reason_str = to_string(reason)

        if String.contains?(reason_str, "connection refused") or
             String.contains?(reason_str, "ECONNREFUSED") do
          {:snooze, 30_000, "Ollama not available: #{reason_str}"}
        else
          {:error, reason_str}
        end
    end
  end

  defp get_config do
    Cham.Plugin.Config.read("summarize_ollama")
  end

  @excerpt_length 280

  @doc """
  Strips Markdown formatting and returns the first #{@excerpt_length} characters
  of the summary as a single line of plain text. Used for the dashboard list
  view blurb.
  """
  def summary_excerpt(markdown) when is_binary(markdown) do
    markdown
    |> String.replace(~r/```[^`]*```/s, " ")
    |> String.replace(~r/`([^`]*)`/, "\\1")
    |> String.replace(~r/!\[[^\]]*\]\([^)]*\)/, " ")
    |> String.replace(~r/\[([^\]]*)\]\([^)]*\)/, "\\1")
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace(~r/^\s{0,3}\#{1,6}\s+/m, "")
    |> String.replace(~r/^\s*[-*+]\s+/m, "")
    |> String.replace(~r/^\s*\d+\.\s+/m, "")
    |> String.replace(~r/^\s*>\s?/m, "")
    |> String.replace(~r/\*\*([^*]+)\*\*/, "\\1")
    |> String.replace(~r/__([^_]+)__/, "\\1")
    |> String.replace(~r/(?<![*\w])\*([^*\n]+)\*(?!\w)/, "\\1")
    |> String.replace(~r/(?<![_\w])_([^_\n]+)_(?!\w)/, "\\1")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, @excerpt_length)
  end
end
