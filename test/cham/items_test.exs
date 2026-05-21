defmodule Cham.ItemsTest do
  use Cham.DataCase

  alias Cham.Items
  alias Cham.Items.{Artifact, Item}

  describe "create_item/1" do
    test "creates an item with valid url" do
      assert {:ok, %Item{} = item} = Items.create_item(%{url: "https://example.com/article"})
      assert item.url == "https://example.com/article"
      assert item.status == "bootstrapping"
      assert item.tags == []
    end

    test "rejects duplicate url" do
      Items.create_item(%{url: "https://example.com/dup"})
      assert {:error, changeset} = Items.create_item(%{url: "https://example.com/dup"})
      assert errors_on(changeset).url != nil
    end

    test "rejects missing url" do
      assert {:error, changeset} = Items.create_item(%{})
      assert errors_on(changeset).url != nil
    end
  end

  describe "get_item/1 and get_item!/1" do
    test "get_item returns item by id" do
      {:ok, item} = Items.create_item(%{url: "https://example.com/get"})
      assert %Item{} = Items.get_item(item.id)
    end

    test "get_item returns nil for missing id" do
      assert nil == Items.get_item(Ecto.UUID.generate())
    end

    test "get_item! raises for missing id" do
      assert_raise Ecto.NoResultsError, fn ->
        Items.get_item!(Ecto.UUID.generate())
      end
    end
  end

  describe "get_item_by_slug_or_id/1" do
    test "finds by full UUID" do
      {:ok, item} = Items.create_item(%{url: "https://example.com/by-uuid"})
      assert {:ok, %Item{id: id}} = Items.get_item_by_slug_or_id(item.id)
      assert id == item.id
    end

    test "finds by slug" do
      {:ok, item} = Items.create_item(%{url: "https://example.com/by-slug"})
      {:ok, item} = Items.update_item(item, %{slug: "my-slug"})
      assert {:ok, %Item{id: id}} = Items.get_item_by_slug_or_id("my-slug")
      assert id == item.id
    end

    test "finds by uuid prefix" do
      {:ok, item} = Items.create_item(%{url: "https://example.com/by-prefix"})
      prefix = String.slice(item.id, 0, 8)
      assert {:ok, %Item{id: id}} = Items.get_item_by_slug_or_id(prefix)
      assert id == item.id
    end

    test "finds by uuid prefix without dashes" do
      {:ok, item} = Items.create_item(%{url: "https://example.com/by-prefix-nodash"})
      prefix = item.id |> String.replace("-", "") |> String.slice(0, 10)
      assert {:ok, %Item{id: id}} = Items.get_item_by_slug_or_id(prefix)
      assert id == item.id
    end

    test "returns :not_found for unknown prefix" do
      assert {:error, :not_found} = Items.get_item_by_slug_or_id("deadbeef")
    end

    test "rejects prefixes shorter than 4 chars" do
      {:ok, _item} = Items.create_item(%{url: "https://example.com/short"})
      assert {:error, :not_found} = Items.get_item_by_slug_or_id("ab")
    end

    test "returns :ambiguous when multiple items share a prefix" do
      # Seed two items, then force their ids to share an 8-char hex prefix.
      {:ok, a} = Items.create_item(%{url: "https://example.com/amb-a"})
      {:ok, b} = Items.create_item(%{url: "https://example.com/amb-b"})

      prefix = "abababab"
      id1 = prefix <> "-1111-1111-1111-111111111111"
      id2 = prefix <> "-2222-2222-2222-222222222222"

      Ecto.Adapters.SQL.query!(Cham.Repo, "UPDATE items SET id = $1 WHERE id = $2", [
        Ecto.UUID.dump!(id1),
        Ecto.UUID.dump!(a.id)
      ])

      Ecto.Adapters.SQL.query!(Cham.Repo, "UPDATE items SET id = $1 WHERE id = $2", [
        Ecto.UUID.dump!(id2),
        Ecto.UUID.dump!(b.id)
      ])

      assert {:error, :ambiguous} = Items.get_item_by_slug_or_id(prefix)
    end
  end

  describe "update_item/2" do
    test "updates item fields" do
      {:ok, item} = Items.create_item(%{url: "https://example.com/update"})

      assert {:ok, updated} =
               Items.update_item(item, %{
                 status: "processing",
                 title: "Test Article",
                 slug: "test-article-abc123",
                 archive_path: "archive/2026/04/04/test-article-abc123"
               })

      assert updated.status == "processing"
      assert updated.title == "Test Article"
      assert updated.slug == "test-article-abc123"
    end

    test "rejects invalid status" do
      {:ok, item} = Items.create_item(%{url: "https://example.com/bad-status"})
      assert {:error, changeset} = Items.update_item(item, %{status: "invalid"})
      assert errors_on(changeset).status != nil
    end
  end

  describe "delete_item/1" do
    test "deletes item and associated artifacts" do
      {:ok, item} = Items.create_item(%{url: "https://example.com/delete"})

      Items.create_artifact(%{
        item_id: item.id,
        stage: "test_stage",
        path: "processing/test-20260404T120000Z",
        labels: %{"origin" => "original"}
      })

      assert {:ok, _} = Items.delete_item(item)
      assert nil == Items.get_item(item.id)
    end
  end

  describe "list_items/1" do
    test "lists all items" do
      Items.create_item(%{url: "https://example.com/list1"})
      Items.create_item(%{url: "https://example.com/list2"})
      assert length(Items.list_items()) == 2
    end

    test "filters by status" do
      {:ok, item1} = Items.create_item(%{url: "https://example.com/filter1"})
      {:ok, _item2} = Items.create_item(%{url: "https://example.com/filter2"})
      Items.update_item(item1, %{status: "complete"})

      assert length(Items.list_items(status: "complete")) == 1
      assert length(Items.list_items(status: "bootstrapping")) == 1
    end
  end

  describe "create_artifact/1" do
    test "creates artifact for an item" do
      {:ok, item} = Items.create_item(%{url: "https://example.com/artifact"})

      assert {:ok, %Artifact{} = artifact} =
               Items.create_artifact(%{
                 item_id: item.id,
                 stage: "transcribe_whisper",
                 path: "processing/transcribe_whisper-20260404T120000Z",
                 labels: %{"origin" => "derived", "format" => "text", "type" => "transcript"},
                 filenames: ["transcript.md"],
                 status: "produced"
               })

      assert artifact.stage == "transcribe_whisper"
      assert artifact.labels["type"] == "transcript"
    end
  end

  describe "list_artifacts/1" do
    test "lists artifacts for an item" do
      {:ok, item} = Items.create_item(%{url: "https://example.com/artifacts"})

      Items.create_artifact(%{
        item_id: item.id,
        stage: "download",
        path: "processing/download-20260404T120000Z",
        labels: %{"origin" => "original"}
      })

      Items.create_artifact(%{
        item_id: item.id,
        stage: "transcribe",
        path: "processing/transcribe-20260404T120100Z",
        labels: %{"origin" => "derived"}
      })

      artifacts = Items.list_artifacts(item.id)
      assert length(artifacts) == 2
    end
  end
end
