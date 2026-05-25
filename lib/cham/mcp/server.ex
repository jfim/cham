defmodule Cham.MCP.Server do
  @moduledoc "Cham's MCP server. Exposes archived articles to MCP-capable clients."

  use Anubis.Server,
    name: "cham",
    version: "0.1.0",
    capabilities: [:tools]

  component(Cham.MCP.Tools.GetArticleMarkdown)
  # TODO: enabled in Task 8-9
  # component(Cham.MCP.Tools.SearchArticles)

  @impl true
  def init(_client_info, frame), do: {:ok, frame}
end
