defmodule Cham.Plugins.ExtractFeedItemsTest do
  use ExUnit.Case, async: true

  alias Cham.Plugins.ExtractFeedItems.Stage, as: FeedStage

  defp fixture(name), do: File.read!(Path.join(["test", "support", "fixtures", "feeds", name]))

  test "stage writes feed metadata artifact from rss xml" do
    working_dir = Path.join(System.tmp_dir!(), "feed_stage_test_#{System.unique_integer([:positive])}")
    input_dir = Path.join(working_dir, "in")
    File.mkdir_p!(input_dir)
    File.mkdir_p!(working_dir)
    File.write!(Path.join(input_dir, "original"), fixture("rss_2.xml"))

    input = %{
      labels: %{"origin" => "original", "format" => "feed"},
      filenames: ["original"],
      input_path: input_dir
    }

    {:ok, result} = FeedStage.perform([input], working_dir, [], "item-id")

    [artifact] = result.artifacts
    assert artifact.labels == %{"origin" => "derived", "type" => "feed_metadata"}
    [file] = artifact.filenames
    parsed = Path.join(working_dir, file) |> File.read!() |> Jason.decode!()

    assert parsed["title"] == "Example Blog"
    assert parsed["subscription_backend"] == "cham_rss"
    assert length(parsed["entries"]) == 2
    first = hd(parsed["entries"])
    assert first["url"] == "https://example.com/p/2"
    assert first["source_item_id"] == "urn:example:2"
  end
end
