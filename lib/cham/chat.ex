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

  @spec default_system_prompt() :: String.t()
  def default_system_prompt, do: @default_system_prompt
end
