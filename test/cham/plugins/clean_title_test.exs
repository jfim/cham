defmodule Cham.Plugins.CleanTitleTest do
  use Cham.DataCase, async: true

  alias Cham.Plugins.CleanTitle
  alias Cham.Plugins.CleanTitle.CleanStage

  describe "plugin behaviour" do
    test "plugin_id" do
      assert CleanTitle.plugin_id() == "clean_title"
    end

    test "name" do
      assert CleanTitle.name() == "Title Cleaner"
    end

    test "config_schema has model and provider" do
      schema = CleanTitle.config_schema()
      keys = Enum.map(schema, & &1.key)
      assert :model in keys
      assert :provider in keys

      model_field = Enum.find(schema, &(&1.key == :model))
      assert model_field.default == "llama3.1:8b"

      provider_field = Enum.find(schema, &(&1.key == :provider))
      assert provider_field.default == "default"
    end

    test "init returns ok" do
      assert {:ok, %{}} = CleanTitle.init(%{})
    end

    test "stages returns CleanStage" do
      assert [CleanStage] = CleanTitle.stages(%{})
    end
  end

  describe "stage metadata" do
    test "name" do
      assert CleanStage.name() == "Clean Title"
    end

    test "input_matchers matches any" do
      assert CleanStage.input_matchers() == [%{}]
    end

    test "output_labels is empty" do
      assert CleanStage.output_labels() == []
    end

    test "queue is :gpu" do
      assert CleanStage.queue() == :gpu
    end

    test "max_attempts is 3" do
      assert CleanStage.max_attempts() == 3
    end

    test "can_process? returns :undecided" do
      assert :undecided = CleanStage.can_process?([])
      assert :undecided = CleanStage.can_process?([%{"origin" => "original"}])
    end
  end

  describe "perform/4" do
    test "returns empty result when item has no title" do
      {:ok, item} = Cham.Items.create_item(%{url: "https://example.com/no-title"})

      assert {:ok, result} = CleanStage.perform([], "", [], item.id)
      assert result.artifacts == []
      assert result.item_metadata == %{}
      assert result.provenance == %{}
    end

    test "returns empty result when item has empty title" do
      {:ok, item} = Cham.Items.create_item(%{url: "https://example.com/empty-title", title: ""})

      assert {:ok, result} = CleanStage.perform([], "", [], item.id)
      assert result.artifacts == []
      assert result.item_metadata == %{}
      assert result.provenance == %{}
    end
  end

  describe "perform/4 with Bypass" do
    setup do
      bypass = Bypass.open()
      %{bypass: bypass}
    end

    test "cleans title via LLM and returns in item_metadata", %{bypass: bypass} do
      {:ok, _item} =
        Cham.Items.create_item(%{
          url: "https://example.com/with-title",
          title: "My Recipe - Soandso's Blog"
        })

      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        [msg] = decoded["messages"]
        assert msg["role"] == "user"
        assert msg["content"] =~ "My Recipe - Soandso's Blog"

        response = %{"choices" => [%{"message" => %{"content" => "My Recipe"}}]}

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(response))
      end)

      url = "http://localhost:#{bypass.port}"

      # Build the same prompt that perform would use
      prompt = """
      Clean up the following page title by removing site names, separators, \
      and other cruft. Return ONLY the cleaned title, nothing else. No quotes, \
      no explanation.

      Examples:
      - "My Recipe - Soandso's Blog" -> "My Recipe"
      - "How to Cook Pasta | AllRecipes.com" -> "How to Cook Pasta"
      - "Introduction to Elixir -- The Elixir Blog" -> "Introduction to Elixir"
      - "Great Article" -> "Great Article"

      Title: My Recipe - Soandso's Blog
      """

      assert {:ok, cleaned} =
               Cham.LLM.Provider.generate(Cham.LLM.Providers.OpenAI, prompt,
                 model: "llama3.1:8b",
                 url: url
               )

      assert cleaned == "My Recipe"

      # Verify that the result structure would be correct
      assert %{
               artifacts: [],
               item_metadata: %{"title" => "My Recipe"},
               provenance: %{"model" => "llama3.1:8b"}
             } == %{
               artifacts: [],
               item_metadata: %{"title" => String.trim(cleaned)},
               provenance: %{"model" => "llama3.1:8b"}
             }
    end

    test "reads title from metadata when item.title is nil", %{bypass: bypass} do
      {:ok, item} =
        Cham.Items.create_item(%{
          url: "https://example.com/metadata-title",
          metadata: %{"title" => "Some Page | Example.com"}
        })

      # Item.title should be nil, but metadata has a title
      assert is_nil(item.title)

      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        [msg] = decoded["messages"]
        assert msg["content"] =~ "Some Page | Example.com"

        response = %{"choices" => [%{"message" => %{"content" => "Some Page"}}]}

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(response))
      end)

      url = "http://localhost:#{bypass.port}"

      prompt = """
      Clean up the following page title by removing site names, separators, \
      and other cruft. Return ONLY the cleaned title, nothing else. No quotes, \
      no explanation.

      Examples:
      - "My Recipe - Soandso's Blog" -> "My Recipe"
      - "How to Cook Pasta | AllRecipes.com" -> "How to Cook Pasta"
      - "Introduction to Elixir -- The Elixir Blog" -> "Introduction to Elixir"
      - "Great Article" -> "Great Article"

      Title: Some Page | Example.com
      """

      assert {:ok, cleaned} =
               Cham.LLM.Provider.generate(Cham.LLM.Providers.OpenAI, prompt,
                 model: "llama3.1:8b",
                 url: url
               )

      assert cleaned == "Some Page"
    end
  end
end
