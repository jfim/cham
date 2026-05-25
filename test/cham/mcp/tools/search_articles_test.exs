defmodule Cham.MCP.Tools.SearchArticlesTest do
  use Cham.DataCase, async: true

  alias Cham.Items
  alias Cham.MCP.Tools.SearchArticles

  defp insert_article(title) do
    n = System.unique_integer([:positive])

    {:ok, item} =
      Items.create_item(%{
        url: "https://example.com/#{n}",
        content_type: "article",
        status: "complete",
        title: title,
        slug: "s-#{n}"
      })

    item
  end

  defp call(params) do
    SearchArticles.execute(params, Anubis.Server.Frame.new())
  end

  test "returns matching articles as JSON list" do
    a = insert_article("Bayesian methods for cats")
    _b = insert_article("Quantum dogs")

    {:reply, response, _frame} = call(%{query: "Bayesian", limit: 10})
    refute response.isError
    text = response.content |> hd() |> Map.fetch!("text")
    decoded = Jason.decode!(text)
    assert is_list(decoded)
    titles = Enum.map(decoded, & &1["title"])
    assert "Bayesian methods for cats" in titles
    refute "Quantum dogs" in titles

    [first | _] = decoded
    assert first["id"] == a.id
    assert first["slug"] == a.slug
    assert first["url"]
    assert Map.has_key?(first, "tags")
    assert Map.has_key?(first, "inserted_at")
    refute Map.has_key?(first, "content")
  end

  test "honors limit" do
    for i <- 1..5, do: insert_article("Common term #{i}")
    {:reply, response, _frame} = call(%{query: "Common", limit: 2})
    refute response.isError
    decoded = response.content |> hd() |> Map.fetch!("text") |> Jason.decode!()
    assert length(decoded) == 2
  end
end
