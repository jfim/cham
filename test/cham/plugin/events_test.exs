defmodule Cham.Plugin.EventsTest do
  use ExUnit.Case, async: true
  alias Cham.Plugin.Events
  alias Cham.Plugin.Events.PluginEvent

  test "builds a status event with a plugin/context and a topic" do
    ev = Events.new("extract_article", "item-1", :status, %{"message" => "Loading model"})

    assert %PluginEvent{
             plugin_id: "extract_article",
             context_id: "item-1",
             type: :status,
             data: %{"message" => "Loading model"}
           } = ev

    assert Events.topic(ev) == "plugin:extract_article"
  end

  test "from_line/3 parses a JSONL status line into a typed event" do
    assert {:ok, %PluginEvent{type: :status, data: %{"message" => "hi"}}} =
             Events.from_line(~s({"event":"status","message":"hi"}), "p", "c")
  end

  test "from_line/3 parses progress and log events" do
    assert {:ok, %PluginEvent{type: :progress, data: %{"value" => 80}}} =
             Events.from_line(~s({"event":"progress","value":80}), "p", "c")

    assert {:ok, %PluginEvent{type: :log, data: %{"level" => "warn"}}} =
             Events.from_line(~s({"event":"log","level":"warn","message":"x"}), "p", "c")
  end

  test "from_line/3 ignores non-JSON or eventless lines" do
    assert :ignore = Events.from_line("not json", "p", "c")
    assert :ignore = Events.from_line(~s({"no":"event"}), "p", "c")
    assert :ignore = Events.from_line(~s({"event":"mystery"}), "p", "c")
  end
end
