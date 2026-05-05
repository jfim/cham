defmodule Cham.Chat do
  @moduledoc """
  Per-item conversational chat against archived content.

  Persists turns to `<item.archive_path>/chats/0001.jsonl`. The system
  prompt is rebuilt on every request from current config and current
  item content; it is never persisted.
  """

  @default_system_prompt """
  You are discussing a {{content_type}} titled "{{title}}".
  Here is the content:

  {{content}}

  Answer questions about this content. Be concise and helpful.
  """

  require Logger

  alias Cham.Items
  alias Cham.Items.Artifact
  alias Cham.Items.Item

  @chat_filename "0001.jsonl"

  @type turn :: %{role: String.t(), content: String.t(), ts: String.t()}

  @spec default_system_prompt() :: String.t()
  def default_system_prompt, do: @default_system_prompt

  @spec build_system_prompt(Item.t(), String.t()) :: String.t()
  def build_system_prompt(%Item{} = item, content) when is_binary(content) do
    template = config()[:system_prompt] || @default_system_prompt

    template
    |> String.replace("{{content_type}}", item.content_type || "document")
    |> String.replace("{{title}}", item.title || item.url || "")
    |> String.replace("{{content}}", content)
  end

  @spec config() :: map()
  def config do
    case Cham.Config.Manager.read_all("chat") do
      {:ok, values} -> values
      _ -> default_config()
    end
  end

  @spec load_history(Item.t()) :: [turn]
  def load_history(%Item{archive_path: nil}), do: []

  def load_history(%Item{archive_path: dir}) do
    path = chat_file_path(dir)

    case File.read(path) do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.flat_map(&decode_line/1)

      {:error, :enoent} ->
        []

      {:error, reason} ->
        Logger.warning("chat: failed to read #{path}: #{inspect(reason)}")
        []
    end
  end

  @spec append_turn(Item.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def append_turn(%Item{archive_path: nil}, _role, _content), do: {:error, :no_archive_path}

  def append_turn(%Item{archive_path: dir}, role, content)
      when role in ["user", "assistant"] and is_binary(content) do
    path = chat_file_path(dir)

    line =
      Jason.encode!(%{
        role: role,
        content: content,
        ts: DateTime.utc_now() |> DateTime.to_iso8601()
      }) <> "\n"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, line, [:append]) do
      :ok
    end
  end

  @spec resolve_content(Item.t(), [Artifact.t()]) :: {String.t() | nil, String.t() | nil}
  def resolve_content(%Item{} = item, artifacts) when is_list(artifacts) do
    primary_type =
      case item.content_type do
        ct when ct in ["video", "podcast"] -> "transcript"
        _ -> "content"
      end

    primary_label = if primary_type == "transcript", do: "transcript", else: "article"

    cond do
      artifact = produced_derived(artifacts, primary_type) ->
        read_with_label(item, artifact, primary_label)

      artifact = produced_derived(artifacts, "summary") ->
        read_with_label(item, artifact, "summary")

      true ->
        {nil, nil}
    end
  end

  defp produced_derived(artifacts, type) do
    Enum.find(artifacts, fn a ->
      a.status == "produced" and
        (a.labels || %{})["origin"] == "derived" and
        (a.labels || %{})["type"] == type
    end)
  end

  defp read_with_label(item, artifact, label) do
    case Items.read_artifact_content(item, artifact) do
      {:ok, body} -> {body, label}
      _ -> {nil, nil}
    end
  end

  defp chat_file_path(dir), do: Path.join([dir, "chats", @chat_filename])

  defp decode_line(line) do
    case Jason.decode(line) do
      {:ok, %{"role" => role, "content" => content} = m} ->
        [%{role: role, content: content, ts: Map.get(m, "ts", "")}]

      _ ->
        Logger.warning("chat: skipping malformed history line: #{inspect(line)}")
        []
    end
  end

  @spec send_message(Item.t(), [Artifact.t()], String.t(), keyword()) ::
          {:ok, [turn]} | {:error, term()}
  def send_message(%Item{} = item, artifacts, user_text, opts \\ [])
      when is_binary(user_text) do
    cfg = Map.merge(config(), Map.new(opts))

    case resolve_content(item, artifacts) do
      {nil, nil} ->
        {:error, :no_content}

      {content, _label} ->
        truncated = truncate_content(content, cfg[:max_input_tokens] || 32_000)
        system_prompt = build_system_prompt(item, truncated)

        history = load_history(item)

        with :ok <- append_turn(item, "user", user_text) do
          messages =
            [%{"role" => "system", "content" => system_prompt}] ++
              Enum.map(history, &%{"role" => &1.role, "content" => &1.content}) ++
              [%{"role" => "user", "content" => user_text}]

          llm_opts = [
            model: cfg[:model],
            url: cfg[:url],
            api_key: cfg[:api_key]
          ]

          case Cham.LLM.Providers.OpenAI.chat(messages, llm_opts) do
            {:ok, reply} ->
              with :ok <- append_turn(item, "assistant", reply) do
                {:ok, load_history(item)}
              end

            {:error, reason} ->
              {:error, reason}
          end
        end
    end
  end

  defp truncate_content(content, max_input_tokens) do
    String.slice(content, 0, max_input_tokens * 4)
  end

  defp default_config do
    %{
      model: "llama3.1:8b",
      url: "http://localhost:11434",
      api_key: nil,
      max_input_tokens: 32_000,
      system_prompt: @default_system_prompt
    }
  end
end
