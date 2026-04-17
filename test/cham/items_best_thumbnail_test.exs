defmodule Cham.Items.BestThumbnailTest do
  use Cham.DataCase, async: false

  alias Cham.Items

  defp produce_thumbnail(item, provider) do
    {:ok, artifact} =
      Items.create_artifact(%{
        item_id: item.id,
        stage: "extract_thumbnail_#{provider}",
        path: "extract_thumbnail_#{provider}",
        labels: %{
          "origin" => "derived",
          "type" => "thumbnail",
          "provider" => provider,
          "content_type" => "image/jpeg"
        },
        filenames: ["thumb.jpg"],
        status: "produced"
      })

    artifact
  end

  defp new_item(attrs \\ %{}) do
    {:ok, item} =
      Items.create_item(
        Map.merge(
          %{url: "https://example.com/video#{System.unique_integer([:positive])}"},
          attrs
        )
      )

    item
  end

  describe "best_thumbnail_url/1" do
    test "returns nil when no thumbnail artifacts exist" do
      item = new_item()
      assert is_nil(Items.best_thumbnail_url(item))
    end

    test "returns URL when ffmpeg (default) provider is present" do
      item = new_item()
      produce_thumbnail(item, "ffmpeg")

      assert Items.best_thumbnail_url(item) =~ "/files/thumb.jpg"
    end

    test "returns any available thumbnail if none match the configured order" do
      item = new_item()
      produce_thumbnail(item, "some_other_provider")

      assert Items.best_thumbnail_url(item) =~ "/files/thumb.jpg"
    end
  end
end
