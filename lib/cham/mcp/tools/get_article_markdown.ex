defmodule Cham.MCP.Tools.GetArticleMarkdown do
  @moduledoc "Fetch the markdown body of an archived article by slug or UUID prefix."

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias Cham.Items

  schema do
    field(:id, {:required, :string}, description: "Item slug or UUID (full or >=4-char prefix)")
  end

  @impl true
  def execute(%{id: id}, frame) do
    with {:ok, item} <- Items.get_item_by_slug_or_id(id),
         :ok <- check_article(item),
         {:ok, body} <- Items.read_primary_markdown(item) do
      text = format(item, body)
      {:reply, Response.tool() |> Response.text(text), frame}
    else
      {:error, :not_found} ->
        {:reply, error("No item found for id #{inspect(id)}"), frame}

      {:error, :ambiguous} ->
        {:reply, error("Ambiguous id prefix #{inspect(id)} — provide more characters"), frame}

      {:error, :not_an_article} ->
        {:reply, error("Item #{inspect(id)} is not an article"), frame}

      {:error, :not_ready} ->
        {:reply, error("Item #{inspect(id)} is not ready yet (still processing)"), frame}
    end
  end

  defp check_article(%{content_type: "article"}), do: :ok
  defp check_article(_), do: {:error, :not_an_article}

  defp format(item, body) do
    """
    # #{item.title || "(untitled)"}
    Source: #{item.url}

    #{body}
    """
  end

  defp error(msg) do
    Response.tool() |> Response.error(msg)
  end
end
