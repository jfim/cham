defmodule Cham.ItemsPrimaryMarkdownTest do
  use Cham.DataCase, async: true

  alias Cham.Items

  setup do
    tmp = Path.join(System.tmp_dir!(), "cham-pm-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  defp insert_article(tmp, status \\ "complete") do
    {:ok, item} =
      Items.create_item(%{
        url: "https://example.com/#{System.unique_integer([:positive])}",
        content_type: "article",
        status: status,
        title: "T"
      })

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

  test "returns cleaned_content body when present", %{tmp: tmp} do
    item = insert_article(tmp)
    write_artifact!(item, "cleaned_content", "derived", "cleaned_content.md", "CLEANED")
    write_artifact!(item, "content", "derived", "content.md", "RAW")
    assert {:ok, "CLEANED"} = Items.read_primary_markdown(item)
  end

  test "falls back to content when cleaned_content missing", %{tmp: tmp} do
    item = insert_article(tmp)
    write_artifact!(item, "content", "derived", "content.md", "RAW")
    assert {:ok, "RAW"} = Items.read_primary_markdown(item)
  end

  test "returns :not_found when no markdown artifacts exist", %{tmp: tmp} do
    item = insert_article(tmp)
    assert {:error, :not_found} = Items.read_primary_markdown(item)
  end

  test "returns :not_ready when item is still processing", %{tmp: tmp} do
    item = insert_article(tmp, "processing")
    assert {:error, :not_ready} = Items.read_primary_markdown(item)
  end
end
