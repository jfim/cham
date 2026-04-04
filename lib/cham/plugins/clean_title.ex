defmodule Cham.Plugins.CleanTitle do
  @behaviour Cham.Plugin

  @impl true
  def plugin_id, do: "clean_title"

  @impl true
  def name, do: "Title Cleaner"

  @impl true
  def description, do: "LLM-based title cleanup"

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
    Cham.Config.Manager.register("plugins.clean_title", config_schema())
    {:ok, %{}}
  end

  @impl true
  def stages(_state), do: [__MODULE__.CleanStage]
end

defmodule Cham.Plugins.CleanTitle.CleanStage do
  @behaviour Cham.Stage

  @impl true
  def name, do: "Clean Title"

  @impl true
  def description, do: "Cleans up item titles using an LLM"

  @impl true
  def input_matchers, do: [%{}]

  @impl true
  def output_labels, do: []

  @impl true
  def queue, do: :gpu

  @impl true
  def max_attempts, do: 3

  @impl true
  def can_process?(_current_artifacts), do: :undecided

  @impl true
  def perform(_input_artifacts, _working_dir, _desired, item_id) do
    config = get_config()
    model = Map.get(config, :model, "llama3.1:8b")

    item = Cham.Items.get_item!(item_id)
    title = item.title || (item.metadata && item.metadata["title"])

    if is_nil(title) or title == "" do
      {:ok, %{artifacts: [], item_metadata: %{}, provenance: %{}}}
    else
      prompt = """
      Clean up the following page title by removing site names, separators, \
      and other cruft. Return ONLY the cleaned title, nothing else. No quotes, \
      no explanation.

      Examples:
      - "My Recipe - Soandso's Blog" -> "My Recipe"
      - "How to Cook Pasta | AllRecipes.com" -> "How to Cook Pasta"
      - "Introduction to Elixir -- The Elixir Blog" -> "Introduction to Elixir"
      - "Great Article" -> "Great Article"

      Title: #{title}
      """

      case Cham.LLM.Provider.generate(Cham.LLM.Providers.OpenAI, prompt, model: model) do
        {:ok, cleaned} ->
          cleaned = String.trim(cleaned)

          {:ok,
           %{
             artifacts: [],
             item_metadata: %{"title" => cleaned},
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
    end
  end

  defp get_config do
    Cham.Plugin.Config.read("clean_title")
  end
end
