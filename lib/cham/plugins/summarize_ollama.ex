defmodule Cham.Plugins.SummarizeOllama do
  @behaviour Cham.Plugin

  @impl true
  def plugin_id, do: "summarize_ollama"

  @impl true
  def name, do: "Ollama Summarizer"

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
        key: :provider,
        type: :string,
        default: "default",
        description: "LLM provider name",
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
        max_chars = max_input_tokens * 4
        truncated = String.slice(text, 0, max_chars)

        prompt = """
        Summarize the following text concisely. Focus on the key points and main ideas. \
        Write the summary in Markdown format.

        ---

        #{truncated}
        """

        case Cham.LLM.Provider.generate(Cham.LLM.Providers.OpenAI, prompt, model: model) do
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
               item_metadata: %{},
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

      {:error, reason} ->
        {:error, "Failed to read input file #{text_path}: #{inspect(reason)}"}
    end
  end

  defp get_config do
    Cham.Plugin.Config.read("summarize_ollama")
  end
end
