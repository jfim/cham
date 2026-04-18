defmodule Cham.ItemsQueryTest do
  use Cham.DataCase

  alias Cham.Items

  defp create_item!(url, attrs) do
    {:ok, item} = Items.create_item(%{url: url})
    {:ok, item} = Items.update_item(item, attrs)
    item
  end

  describe "list_items/1 with subscribed-feed filtering" do
    test "default hides feed items whose URL has an existing subscription" do
      {:ok, _sub} =
        Cham.Subscriptions.create_subscription(%{
          source_url: "https://hidden.example/feed",
          backend: "cham_rss",
          title: "Hidden",
          poll_interval_seconds: 86_400
        })

      {:ok, _feed_item} =
        Cham.Items.create_item(%{
          url: "https://hidden.example/feed",
          content_type: "feed"
        })

      {:ok, _regular} = Cham.Items.create_item(%{url: "https://plain.example/post"})

      urls = Cham.Items.list_items() |> Enum.map(& &1.url)
      refute "https://hidden.example/feed" in urls
      assert "https://plain.example/post" in urls

      urls_all =
        Cham.Items.list_items(include_subscribed_feeds: true) |> Enum.map(& &1.url)

      assert "https://hidden.example/feed" in urls_all
    end
  end

  describe "list_items/1 with content_type filter" do
    test "filters by content_type" do
      create_item!("https://example.com/article1", %{content_type: "article"})
      create_item!("https://example.com/article2", %{content_type: "article"})
      create_item!("https://example.com/video1", %{content_type: "video"})

      results = Items.list_items(content_type: "article")
      assert length(results) == 2
      assert Enum.all?(results, fn i -> i.content_type == "article" end)
    end
  end

  describe "list_items/1 with tag filter" do
    test "filters by tag" do
      create_item!("https://example.com/tagged1", %{tags: ["phoenix", "elixir"]})
      create_item!("https://example.com/tagged2", %{tags: ["elixir"]})
      create_item!("https://example.com/untagged", %{tags: []})

      results = Items.list_items(tag: "phoenix")
      assert length(results) == 1
      assert hd(results).url == "https://example.com/tagged1"
    end
  end

  describe "list_items/1 with combined filters" do
    test "filters by content_type and tag together" do
      create_item!("https://example.com/art-phx", %{content_type: "article", tags: ["phoenix"]})
      create_item!("https://example.com/art-elix", %{content_type: "article", tags: ["elixir"]})
      create_item!("https://example.com/vid-phx", %{content_type: "video", tags: ["phoenix"]})

      results = Items.list_items(content_type: "article", tag: "phoenix")
      assert length(results) == 1
      assert hd(results).url == "https://example.com/art-phx"
    end
  end

  describe "list_items/1 ordering" do
    test "orders by inserted_at desc" do
      {:ok, item1} = Items.create_item(%{url: "https://example.com/order1"})
      {:ok, item2} = Items.create_item(%{url: "https://example.com/order2"})
      {:ok, item3} = Items.create_item(%{url: "https://example.com/order3"})

      results = Items.list_items([])

      ids = Enum.map(results, & &1.id)
      assert Enum.member?(ids, item1.id)
      assert Enum.member?(ids, item2.id)
      assert Enum.member?(ids, item3.id)

      # Results should be ordered by inserted_at desc (non-ascending)
      timestamps = Enum.map(results, & &1.inserted_at)
      assert timestamps == Enum.sort(timestamps, {:desc, DateTime})
    end
  end

  describe "count_by_content_type/0" do
    test "returns counts grouped by content_type" do
      create_item!("https://example.com/ct1", %{content_type: "article"})
      create_item!("https://example.com/ct2", %{content_type: "article"})
      create_item!("https://example.com/ct3", %{content_type: "video"})

      counts = Items.count_by_content_type()
      assert counts["article"] == 2
      assert counts["video"] == 1
    end

    test "excludes nil content_type" do
      create_item!("https://example.com/nil-ct", %{})
      create_item!("https://example.com/has-ct", %{content_type: "article"})

      counts = Items.count_by_content_type()
      refute Map.has_key?(counts, nil)
      assert counts["article"] == 1
    end
  end

  describe "count_by_tag/0" do
    test "returns counts across all items' tag arrays" do
      create_item!("https://example.com/tags1", %{tags: ["elixir", "phoenix"]})
      create_item!("https://example.com/tags2", %{tags: ["elixir"]})
      create_item!("https://example.com/tags3", %{tags: ["phoenix"]})

      counts = Items.count_by_tag()
      assert counts["elixir"] == 2
      assert counts["phoenix"] == 2
    end

    test "returns empty map when no tags" do
      create_item!("https://example.com/notags", %{tags: []})

      counts = Items.count_by_tag()
      assert counts == %{}
    end
  end

  describe "list_in_progress_items/0" do
    test "returns items with in-progress statuses" do
      {:ok, bootstrapping} = Items.create_item(%{url: "https://example.com/boot"})

      {:ok, processing} = Items.create_item(%{url: "https://example.com/proc"})
      Items.update_item(processing, %{status: "processing"})

      {:ok, failed} = Items.create_item(%{url: "https://example.com/fail"})
      Items.update_item(failed, %{status: "failed"})

      {:ok, incomplete} = Items.create_item(%{url: "https://example.com/incomplete"})
      Items.update_item(incomplete, %{status: "incomplete"})

      {:ok, complete} = Items.create_item(%{url: "https://example.com/complete"})
      Items.update_item(complete, %{status: "complete"})

      results = Items.list_in_progress_items()
      result_ids = Enum.map(results, & &1.id)

      assert bootstrapping.id in result_ids
      assert processing.id in result_ids
      assert failed.id in result_ids
      refute incomplete.id in result_ids
      refute complete.id in result_ids
    end

    test "orders by inserted_at desc" do
      {:ok, _item1} = Items.create_item(%{url: "https://example.com/prog1"})
      {:ok, _item2} = Items.create_item(%{url: "https://example.com/prog2"})

      results = Items.list_in_progress_items()

      # Results should be ordered by inserted_at desc (non-ascending)
      timestamps = Enum.map(results, & &1.inserted_at)
      assert timestamps == Enum.sort(timestamps, {:desc, DateTime})
    end
  end

  describe "read_artifact_content/2" do
    test "reads file content using archive_path" do
      tmp_dir = System.tmp_dir!()
      artifact_path = "processing/test-stage-20260404T120000Z"
      filename = "content.txt"
      full_dir = Path.join([tmp_dir, artifact_path])
      File.mkdir_p!(full_dir)
      file_path = Path.join(full_dir, filename)
      File.write!(file_path, "hello world")

      {:ok, item} = Items.create_item(%{url: "https://example.com/read-art"})
      {:ok, item} = Items.update_item(item, %{archive_path: tmp_dir})

      {:ok, artifact} =
        Items.create_artifact(%{
          item_id: item.id,
          stage: "test-stage",
          path: artifact_path,
          filenames: [filename],
          labels: %{}
        })

      assert {:ok, "hello world"} = Items.read_artifact_content(item, artifact)

      File.rm!(file_path)
      File.rmdir!(full_dir)
    end

    test "reads file content using bootstrap_path when archive_path is nil" do
      tmp_dir = System.tmp_dir!()
      artifact_path = "processing/boot-stage-20260404T120000Z"
      filename = "boot.txt"
      full_dir = Path.join([tmp_dir, artifact_path])
      File.mkdir_p!(full_dir)
      file_path = Path.join(full_dir, filename)
      File.write!(file_path, "bootstrap content")

      {:ok, item} = Items.create_item(%{url: "https://example.com/read-boot"})
      {:ok, item} = Items.update_item(item, %{bootstrap_path: tmp_dir})

      {:ok, artifact} =
        Items.create_artifact(%{
          item_id: item.id,
          stage: "boot-stage",
          path: artifact_path,
          filenames: [filename],
          labels: %{}
        })

      assert {:ok, "bootstrap content"} = Items.read_artifact_content(item, artifact)

      File.rm!(file_path)
      File.rmdir!(full_dir)
    end

    test "returns error for missing file" do
      {:ok, item} = Items.create_item(%{url: "https://example.com/missing-art"})
      {:ok, item} = Items.update_item(item, %{archive_path: "/nonexistent/path"})

      {:ok, artifact} =
        Items.create_artifact(%{
          item_id: item.id,
          stage: "missing-stage",
          path: "nonexistent/path",
          filenames: ["missing.txt"],
          labels: %{}
        })

      assert {:error, _} = Items.read_artifact_content(item, artifact)
    end
  end
end
