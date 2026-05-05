defmodule Cham.ChatTest do
  use ExUnit.Case, async: true

  alias Cham.Chat
  alias Cham.Items.Item

  describe "default_system_prompt/0" do
    test "contains the documented placeholders" do
      template = Chat.default_system_prompt()
      assert template =~ "{{content_type}}"
      assert template =~ "{{title}}"
      assert template =~ "{{content}}"
    end
  end

  describe "build_system_prompt/2" do
    test "substitutes title, content_type, and content" do
      item = %Item{title: "Hello World", url: "https://x", content_type: "article"}
      prompt = Chat.build_system_prompt(item, "the body")
      assert prompt =~ ~s|titled "Hello World"|
      assert prompt =~ "discussing a article"
      assert prompt =~ "the body"
    end

    test "falls back to URL when title is nil" do
      item = %Item{title: nil, url: "https://example.com/x", content_type: "article"}
      prompt = Chat.build_system_prompt(item, "body")
      assert prompt =~ ~s|titled "https://example.com/x"|
    end

    test "falls back to 'document' when content_type is nil" do
      item = %Item{title: "T", url: "https://x", content_type: nil}
      prompt = Chat.build_system_prompt(item, "body")
      assert prompt =~ "discussing a document"
    end
  end

  describe "load_history/1 and append_turn/3" do
    setup do
      tmp = System.tmp_dir!() |> Path.join("cham-chat-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)
      item = %Item{archive_path: tmp}
      %{item: item, tmp: tmp}
    end

    test "load returns [] when no chat file exists", %{item: item} do
      assert Chat.load_history(item) == []
    end

    test "append then load round-trips turns in order", %{item: item, tmp: tmp} do
      :ok = Chat.append_turn(item, "user", "first")
      :ok = Chat.append_turn(item, "assistant", "reply")
      :ok = Chat.append_turn(item, "user", "second")

      history = Chat.load_history(item)

      assert [
               %{role: "user", content: "first"},
               %{role: "assistant", content: "reply"},
               %{role: "user", content: "second"}
             ] = history

      assert File.exists?(Path.join([tmp, "chats", "0001.jsonl"]))
    end

    test "load skips malformed lines and keeps valid ones", %{item: item, tmp: tmp} do
      path = Path.join([tmp, "chats", "0001.jsonl"])
      File.mkdir_p!(Path.dirname(path))

      File.write!(path, """
      {"role":"user","content":"a","ts":"2026-05-05T00:00:00Z"}
      not-json
      {"role":"assistant","content":"b","ts":"2026-05-05T00:00:01Z"}
      """)

      history = Chat.load_history(item)
      assert [%{role: "user", content: "a"}, %{role: "assistant", content: "b"}] = history
    end

    test "load returns [] when archive_path is nil" do
      assert Chat.load_history(%Item{archive_path: nil}) == []
    end

    test "append returns error when archive_path is nil" do
      assert {:error, :no_archive_path} = Chat.append_turn(%Item{archive_path: nil}, "user", "x")
    end
  end

  describe "resolve_content/2" do
    setup do
      tmp = System.tmp_dir!() |> Path.join("cham-resolve-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)
      %{tmp: tmp}
    end

    defp write_artifact!(tmp, subdir, file, body) do
      dir = Path.join(tmp, subdir)
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, file), body)

      %Cham.Items.Artifact{
        path: subdir,
        filenames: [file],
        status: "produced",
        labels: %{}
      }
    end

    test "prefers article content over summary", %{tmp: tmp} do
      item = %Item{archive_path: tmp, content_type: "article"}

      content =
        %{
          write_artifact!(tmp, "content", "content.md", "ARTICLE BODY")
          | labels: %{"origin" => "derived", "type" => "content"}
        }

      summary =
        %{
          write_artifact!(tmp, "summary", "summary.md", "SUM")
          | labels: %{"origin" => "derived", "type" => "summary"}
        }

      assert {"ARTICLE BODY", "article"} = Chat.resolve_content(item, [content, summary])
    end

    test "prefers transcript over summary for video items", %{tmp: tmp} do
      item = %Item{archive_path: tmp, content_type: "video"}

      transcript =
        %{
          write_artifact!(tmp, "transcript", "t.md", "TRANSCRIPT")
          | labels: %{"origin" => "derived", "type" => "transcript"}
        }

      summary =
        %{
          write_artifact!(tmp, "summary", "summary.md", "SUM")
          | labels: %{"origin" => "derived", "type" => "summary"}
        }

      assert {"TRANSCRIPT", "transcript"} = Chat.resolve_content(item, [transcript, summary])
    end

    test "falls back to summary when no primary content", %{tmp: tmp} do
      item = %Item{archive_path: tmp, content_type: "article"}

      summary =
        %{
          write_artifact!(tmp, "summary", "summary.md", "SUM")
          | labels: %{"origin" => "derived", "type" => "summary"}
        }

      assert {"SUM", "summary"} = Chat.resolve_content(item, [summary])
    end

    test "returns {nil, nil} when nothing is available", %{tmp: tmp} do
      item = %Item{archive_path: tmp, content_type: "article"}
      assert {nil, nil} = Chat.resolve_content(item, [])
    end
  end

  describe "send_message/3" do
    setup do
      bypass = Bypass.open()

      tmp = System.tmp_dir!() |> Path.join("cham-send-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      content_artifact = %Cham.Items.Artifact{
        path: "content",
        filenames: ["content.md"],
        status: "produced",
        labels: %{"origin" => "derived", "type" => "content"}
      }

      File.mkdir_p!(Path.join(tmp, "content"))
      File.write!(Path.join([tmp, "content", "content.md"]), "BODY")

      item = %Cham.Items.Item{
        archive_path: tmp,
        content_type: "article",
        title: "T",
        url: "https://x"
      }

      %{bypass: bypass, item: item, artifacts: [content_artifact]}
    end

    test "calls LLM with system + history + user, persists both turns",
         %{bypass: bypass, item: item, artifacts: artifacts} do
      previous_seed = """
      {"role":"user","content":"earlier","ts":"2026-05-04T00:00:00Z"}
      {"role":"assistant","content":"earlier reply","ts":"2026-05-04T00:00:01Z"}
      """

      File.mkdir_p!(Path.join(item.archive_path, "chats"))
      File.write!(Path.join([item.archive_path, "chats", "0001.jsonl"]), previous_seed)

      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        roles = Enum.map(decoded["messages"], & &1["role"])
        assert roles == ["system", "user", "assistant", "user"]

        system_msg = hd(decoded["messages"])["content"]
        assert system_msg =~ ~s|titled "T"|
        assert system_msg =~ "BODY"

        last = List.last(decoded["messages"])
        assert last["content"] == "new question"

        resp = %{"choices" => [%{"message" => %{"content" => "the answer"}}]}

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(resp))
      end)

      assert {:ok, history} =
               Chat.send_message(item, artifacts, "new question",
                 url: "http://localhost:#{bypass.port}",
                 model: "test-model"
               )

      assert Enum.map(history, & &1.role) == ["user", "assistant", "user", "assistant"]
      assert List.last(history).content == "the answer"

      # Persisted on disk too
      reloaded = Chat.load_history(item)
      assert Enum.map(reloaded, & &1.role) == ["user", "assistant", "user", "assistant"]
      assert List.last(reloaded).content == "the answer"
    end

    test "returns :no_content when item has neither content nor summary",
         %{bypass: _bypass, item: item} do
      assert {:error, :no_content} = Chat.send_message(item, [], "question", url: "http://unused")
    end

    test "returns LLM error and does not persist assistant turn",
         %{bypass: bypass, item: item, artifacts: artifacts} do
      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
        Plug.Conn.resp(conn, 500, "boom")
      end)

      assert {:error, _} =
               Chat.send_message(item, artifacts, "q",
                 url: "http://localhost:#{bypass.port}",
                 model: "m"
               )

      history = Chat.load_history(item)
      # User turn was persisted optimistically; assistant turn was not.
      assert Enum.map(history, & &1.role) == ["user"]
    end
  end
end
