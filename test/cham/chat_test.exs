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
end
