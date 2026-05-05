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

  alias Cham.Items.Item

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
