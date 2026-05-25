defmodule Cham.MCP.Tools.GetArticleMarkdownTest do
  use Cham.DataCase, async: true

  alias Anubis.Server.Frame
  alias Cham.Items
  alias Cham.MCP.Tools.GetArticleMarkdown

  setup do
    tmp = Path.join(System.tmp_dir!(), "cham-mcp-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  defp create_item!(attrs) do
    n = System.unique_integer([:positive])

    defaults = %{
      url: "https://example.com/#{n}",
      slug: "slug-#{n}",
      content_type: "article",
      status: "complete",
      title: "T#{n}"
    }

    {:ok, item} = Items.create_item(Map.merge(defaults, attrs))
    item
  end

  defp set_archive_path!(item, tmp) do
    {:ok, item} = Items.update_item(item, %{archive_path: tmp})
    item
  end

  defp write_artifact!(item, type, origin, filename, body) do
    stage_dir = Path.join(item.archive_path, type)
    File.mkdir_p!(stage_dir)
    File.write!(Path.join(stage_dir, filename), body)

    {:ok, _} =
      Items.create_artifact(%{
        item_id: item.id,
        stage: type,
        path: type,
        filenames: [filename],
        labels: %{"type" => type, "origin" => origin},
        status: "produced"
      })
  end

  defp seed_article(tmp, body) do
    item = create_item!(%{}) |> set_archive_path!(tmp)
    write_artifact!(item, "content", "derived", "content.md", body)
    item
  end

  defp call(params) do
    GetArticleMarkdown.execute(params, Frame.new())
  end

  test "returns markdown body for slug", %{tmp: tmp} do
    item = seed_article(tmp, "# Hello\n\nbody")
    {:reply, response, _frame} = call(%{id: item.slug})
    refute response.isError
    text = response.content |> hd() |> Map.fetch!("text")
    assert text =~ "# Hello"
    assert text =~ "body"
    assert text =~ item.url
  end

  test "returns error for unknown id" do
    {:reply, response, _frame} = call(%{id: "nope-nope"})
    assert response.isError
  end

  test "returns error for non-article item", %{tmp: tmp} do
    item =
      create_item!(%{content_type: "video", status: "complete"})
      |> set_archive_path!(tmp)

    {:reply, response, _frame} = call(%{id: item.slug})
    assert response.isError
    text = response.content |> hd() |> Map.fetch!("text")
    assert text =~ "not an article"
  end

  test "returns error for still-processing item", %{tmp: tmp} do
    item =
      create_item!(%{status: "processing"})
      |> set_archive_path!(tmp)

    {:reply, response, _frame} = call(%{id: item.slug})
    assert response.isError
    text = response.content |> hd() |> Map.fetch!("text")
    assert text =~ "not ready"
  end
end
