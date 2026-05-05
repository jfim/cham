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
end
