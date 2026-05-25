defmodule Cham.MCP.Tools.SearchArticles do
  @moduledoc "Search archived articles by title/url/excerpt. Returns metadata only."

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias Cham.Items

  schema do
    field(:query, {:required, :string}, description: "Search term")
    field(:limit, :integer, description: "Max results (default 10, capped at 50)")
  end

  @impl true
  def execute(%{query: query} = params, frame) do
    limit = params |> Map.get(:limit) |> normalize_limit()

    {items, _total} =
      Items.list_items_paginated(
        [search: query, content_type: "article"],
        page_size: limit
      )

    payload = Enum.map(items, &compact/1)
    {:reply, Response.tool() |> Response.text(Jason.encode!(payload)), frame}
  end

  defp normalize_limit(n) when is_integer(n), do: n |> max(1) |> min(50)
  defp normalize_limit(_), do: 10

  defp compact(item) do
    %{
      id: item.id,
      slug: item.slug,
      title: item.title,
      url: item.url,
      tags: item.tags || [],
      inserted_at: item.inserted_at && DateTime.to_iso8601(item.inserted_at)
    }
  end
end
