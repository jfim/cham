defmodule ChamWeb.ItemJSON do
  def render("index.json", %{items: items}) do
    %{items: Enum.map(items, &item_json/1)}
  end

  def render("show.json", %{item: item}) do
    item_json(item)
  end

  def render("error.json", %{error: message}) do
    %{error: message}
  end

  defp item_json(item) do
    %{
      id: item.id,
      url: item.url,
      status: item.status,
      title: item.title,
      slug: item.slug,
      content_type: item.content_type,
      tags: item.tags,
      error_message: item.error_message,
      metadata: item.metadata,
      inserted_at: item.inserted_at,
      updated_at: item.updated_at
    }
  end
end
