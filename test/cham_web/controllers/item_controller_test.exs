defmodule ChamWeb.ItemControllerTest do
  use ChamWeb.ConnCase

  alias Cham.Items

  describe "POST /api/v1/items" do
    test "creates an item and returns 202", %{conn: conn} do
      conn = post(conn, "/api/v1/items", %{url: "https://example.com/article", tags: ["test"]})

      assert %{"id" => id, "url" => "https://example.com/article", "status" => "bootstrapping"} =
               json_response(conn, 202)

      assert is_binary(id)
    end

    test "returns 409 for duplicate URL", %{conn: conn} do
      url = "https://example.com/duplicate"
      post(conn, "/api/v1/items", %{url: url})

      conn = post(conn, "/api/v1/items", %{url: url})
      assert %{"error" => _} = json_response(conn, 409)
    end

    test "returns 422 when url is missing", %{conn: conn} do
      conn = post(conn, "/api/v1/items", %{tags: ["test"]})
      assert %{"error" => _} = json_response(conn, 422)
    end
  end

  describe "GET /api/v1/items" do
    test "returns empty list when no items", %{conn: conn} do
      conn = get(conn, "/api/v1/items")
      assert %{"items" => []} = json_response(conn, 200)
    end

    test "returns items", %{conn: conn} do
      {:ok, _} = Items.create_item(%{url: "https://example.com/1", tags: ["a"]})
      {:ok, _} = Items.create_item(%{url: "https://example.com/2", tags: ["b"]})

      conn = get(conn, "/api/v1/items")
      assert %{"items" => items} = json_response(conn, 200)
      assert length(items) == 2
    end

    test "filters by status", %{conn: conn} do
      {:ok, _} = Items.create_item(%{url: "https://example.com/1", status: "complete"})
      {:ok, _} = Items.create_item(%{url: "https://example.com/2", status: "bootstrapping"})

      conn = get(conn, "/api/v1/items", %{status: "complete"})
      assert %{"items" => [item]} = json_response(conn, 200)
      assert item["status"] == "complete"
    end

    test "filters by tag", %{conn: conn} do
      {:ok, _} = Items.create_item(%{url: "https://example.com/1", tags: ["ml", "ai"]})
      {:ok, _} = Items.create_item(%{url: "https://example.com/2", tags: ["web"]})

      conn = get(conn, "/api/v1/items", %{tag: "ml"})
      assert %{"items" => [item]} = json_response(conn, 200)
      assert "ml" in item["tags"]
    end

    test "filters by content_type", %{conn: conn} do
      {:ok, _} = Items.create_item(%{url: "https://example.com/1", content_type: "article"})
      {:ok, _} = Items.create_item(%{url: "https://example.com/2", content_type: "video"})

      conn = get(conn, "/api/v1/items", %{content_type: "article"})
      assert %{"items" => [item]} = json_response(conn, 200)
      assert item["content_type"] == "article"
    end
  end

  describe "GET /api/v1/items/:id" do
    test "returns item by UUID", %{conn: conn} do
      {:ok, item} = Items.create_item(%{url: "https://example.com/1"})

      conn = get(conn, "/api/v1/items/#{item.id}")
      assert %{"id" => id, "url" => "https://example.com/1"} = json_response(conn, 200)
      assert id == item.id
    end

    test "returns item by slug", %{conn: conn} do
      {:ok, item} =
        Items.create_item(%{url: "https://example.com/1", slug: "my-article"})

      conn = get(conn, "/api/v1/items/my-article")
      assert %{"id" => id, "slug" => "my-article"} = json_response(conn, 200)
      assert id == item.id
    end

    test "returns 404 for non-existent item", %{conn: conn} do
      conn = get(conn, "/api/v1/items/#{Ecto.UUID.generate()}")
      assert %{"error" => "not found"} = json_response(conn, 404)
    end

    test "returns 404 for invalid id", %{conn: conn} do
      conn = get(conn, "/api/v1/items/not-a-uuid-or-slug")
      assert %{"error" => "not found"} = json_response(conn, 404)
    end

    test "excludes internal paths from response", %{conn: conn} do
      {:ok, item} =
        Items.create_item(%{url: "https://example.com/1"})

      Items.update_item(item, %{bootstrap_path: "/tmp/bootstrap", archive_path: "/tmp/archive"})

      conn = get(conn, "/api/v1/items/#{item.id}")
      response = json_response(conn, 200)
      refute Map.has_key?(response, "bootstrap_path")
      refute Map.has_key?(response, "archive_path")
    end
  end
end
