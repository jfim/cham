defmodule Cham.Plugins.AutoTagTest do
  use ExUnit.Case, async: true

  alias Cham.Plugins.AutoTag
  alias Cham.Plugins.AutoTag.TagStage

  describe "plugin behaviour" do
    test "plugin_id" do
      assert AutoTag.plugin_id() == "auto_tag"
    end

    test "name" do
      assert AutoTag.name() == "LLM Auto Tagger"
    end

    test "config_schema has model, max_tags, url, and api_key" do
      schema = AutoTag.config_schema()
      keys = Enum.map(schema, & &1.key)
      assert :model in keys
      assert :max_tags in keys
      assert :url in keys
      assert :api_key in keys

      model_field = Enum.find(schema, &(&1.key == :model))
      assert model_field.default == "llama3.1:8b"

      max_tags_field = Enum.find(schema, &(&1.key == :max_tags))
      assert max_tags_field.default == 8
    end

    test "init returns ok" do
      assert {:ok, %{}} = AutoTag.init(%{})
    end

    test "stages returns TagStage" do
      assert [TagStage] = AutoTag.stages(%{})
    end
  end

  describe "stage metadata" do
    test "name" do
      assert TagStage.name() == "Auto Tag"
    end

    test "input_matchers" do
      matchers = TagStage.input_matchers()
      assert length(matchers) == 2

      assert %{"origin" => "original", "format" => "text", "type" => "content"} in matchers
      assert %{"origin" => "derived", "type" => "transcript"} in matchers
    end

    test "output_labels" do
      [label] = TagStage.output_labels()
      assert label["origin"] == "derived"
      assert label["type"] == "tags"
    end

    test "queue is :gpu" do
      assert TagStage.queue() == :gpu
    end

    test "max_attempts is 3" do
      assert TagStage.max_attempts() == 3
    end
  end

  describe "can_process?" do
    test "ready when article text content present" do
      artifacts = [%{"origin" => "original", "format" => "text", "type" => "content"}]
      assert {:ready, _required, []} = TagStage.can_process?(artifacts)
    end

    test "ready when transcript present" do
      artifacts = [%{"origin" => "derived", "type" => "transcript"}]
      assert {:ready, _required, []} = TagStage.can_process?(artifacts)
    end

    test "not applicable when no matching artifacts" do
      artifacts = [%{"origin" => "original", "format" => "video"}]
      assert :not_applicable = TagStage.can_process?(artifacts)
    end

    test "not applicable for empty artifacts" do
      assert :not_applicable = TagStage.can_process?([])
    end
  end

  describe "parse_tags/2" do
    test "parses plain JSON array" do
      response = ~s(["elixir", "web-development", "otp"])
      assert TagStage.parse_tags(response, 10) == ["elixir", "web-development", "otp"]
    end

    test "strips markdown json code block wrapper" do
      response = "```json\n[\"elixir\", \"phoenix\"]\n```"
      assert TagStage.parse_tags(response, 10) == ["elixir", "phoenix"]
    end

    test "strips plain markdown code block wrapper" do
      response = "```\n[\"elixir\", \"phoenix\"]\n```"
      assert TagStage.parse_tags(response, 10) == ["elixir", "phoenix"]
    end

    test "downcases tags" do
      response = ~s(["Elixir", "PHOENIX", "Web-Dev"])
      assert TagStage.parse_tags(response, 10) == ["elixir", "phoenix", "web-dev"]
    end

    test "enforces max_tags limit" do
      response = ~s(["a", "b", "c", "d", "e"])
      assert TagStage.parse_tags(response, 3) == ["a", "b", "c"]
    end

    test "filters out non-string values" do
      response = ~s(["elixir", 42, true, "phoenix", null])
      assert TagStage.parse_tags(response, 10) == ["elixir", "phoenix"]
    end

    test "returns empty list for invalid JSON" do
      assert TagStage.parse_tags("not json at all", 10) == []
    end

    test "returns empty list for non-array JSON" do
      assert TagStage.parse_tags(~s({"tags": ["a"]}), 10) == []
    end
  end

  describe "perform/4 with Bypass" do
    setup do
      bypass = Bypass.open()

      input_dir =
        Path.join(
          System.tmp_dir!(),
          "cham_auto_tag_test_input_#{System.unique_integer([:positive])}"
        )

      working_dir =
        Path.join(
          System.tmp_dir!(),
          "cham_auto_tag_test_work_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(input_dir)
      File.mkdir_p!(working_dir)

      on_exit(fn ->
        File.rm_rf!(input_dir)
        File.rm_rf!(working_dir)
      end)

      %{bypass: bypass, input_dir: input_dir, working_dir: working_dir}
    end

    test "successful tagging via LLM provider with markdown wrapper", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        [msg] = decoded["messages"]
        assert msg["role"] == "user"
        assert msg["content"] =~ "tags"

        tags_response = "```json\n[\"Elixir\", \"web-development\", \"OTP\"]\n```"
        response = %{"choices" => [%{"message" => %{"content" => tags_response}}]}

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(response))
      end)

      url = "http://localhost:#{bypass.port}"

      prompt = "Generate tags for this text"

      assert {:ok, response} =
               Cham.LLM.Provider.generate(Cham.LLM.Providers.OpenAI, prompt,
                 model: "llama3.1:8b",
                 url: url
               )

      tags = TagStage.parse_tags(response, 10)
      assert tags == ["elixir", "web-development", "otp"]
    end

    test "perform writes tags.json to working_dir", %{
      input_dir: input_dir,
      working_dir: working_dir,
      bypass: bypass
    } do
      File.write!(Path.join(input_dir, "article.txt"), "An article about Elixir and Phoenix.")

      tags_response = "```json\n[\"elixir\", \"phoenix\", \"web-framework\"]\n```"

      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
        response = %{"choices" => [%{"message" => %{"content" => tags_response}}]}

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(response))
      end)

      url = "http://localhost:#{bypass.port}"

      text = File.read!(Path.join(input_dir, "article.txt"))
      truncated = String.slice(text, 0, 32_000)

      prompt = """
      Analyze the following text and generate relevant tags for categorization. \
      Return ONLY a JSON array of lowercase, hyphenated tags. No explanation, no markdown. \
      Example: ["machine-learning", "elixir", "web-development"]

      ---

      #{truncated}
      """

      {:ok, response} =
        Cham.LLM.Provider.generate(Cham.LLM.Providers.OpenAI, prompt,
          model: "llama3.1:8b",
          url: url
        )

      tags = TagStage.parse_tags(response, 10)
      output_path = Path.join(working_dir, "tags.json")
      File.write!(output_path, Jason.encode!(tags))

      assert File.exists?(output_path)
      assert Jason.decode!(File.read!(output_path)) == ["elixir", "phoenix", "web-framework"]
    end
  end
end
