defmodule Cham.LLM.Providers.OpenAITest do
  use ExUnit.Case, async: true

  alias Cham.LLM.Providers.OpenAI

  setup do
    bypass = Bypass.open()
    %{bypass: bypass, url: "http://localhost:#{bypass.port}"}
  end

  describe "chat/2" do
    test "returns response text on success", %{bypass: bypass, url: url} do
      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["model"] == "test-model"
        assert length(decoded["messages"]) == 1

        response = %{"choices" => [%{"message" => %{"content" => "Hello from LLM!"}}]}

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(response))
      end)

      messages = [%{"role" => "user", "content" => "Hi"}]
      assert {:ok, "Hello from LLM!"} = OpenAI.chat(messages, model: "test-model", url: url)
    end

    test "returns error on non-200 response", %{bypass: bypass, url: url} do
      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(429, ~s({"error": "rate limited"}))
      end)

      messages = [%{"role" => "user", "content" => "Hi"}]
      assert {:error, msg} = OpenAI.chat(messages, model: "test-model", url: url)
      assert msg =~ "429"
    end

    test "returns error on connection failure" do
      messages = [%{"role" => "user", "content" => "Hi"}]
      assert {:error, msg} = OpenAI.chat(messages, model: "test-model", url: "http://localhost:1")
      assert msg =~ "request failed"
    end

    test "returns error on malformed response", %{bypass: bypass, url: url} do
      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"unexpected": "format"}))
      end)

      messages = [%{"role" => "user", "content" => "Hi"}]

      assert {:error, "failed to parse response"} =
               OpenAI.chat(messages, model: "test-model", url: url)
    end

    test "sends authorization header when api_key is provided", %{bypass: bypass, url: url} do
      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
        auth = Plug.Conn.get_req_header(conn, "authorization")
        assert auth == ["Bearer sk-test-key"]

        response = %{"choices" => [%{"message" => %{"content" => "ok"}}]}

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(response))
      end)

      messages = [%{"role" => "user", "content" => "Hi"}]
      assert {:ok, _} = OpenAI.chat(messages, model: "m", url: url, api_key: "sk-test-key")
    end
  end

  describe "generate/3 via Provider behaviour" do
    test "wraps prompt into single-message chat", %{bypass: bypass, url: url} do
      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        [msg] = decoded["messages"]
        assert msg["role"] == "user"
        assert msg["content"] == "Summarize this"

        response = %{"choices" => [%{"message" => %{"content" => "Summary here"}}]}

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(response))
      end)

      assert {:ok, "Summary here"} =
               Cham.LLM.Provider.generate(OpenAI, "Summarize this", model: "m", url: url)
    end
  end
end
