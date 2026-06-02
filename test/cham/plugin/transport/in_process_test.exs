defmodule Cham.Plugin.Transport.InProcessTest do
  use ExUnit.Case, async: true
  alias Cham.Plugin.Transport.InProcess
  alias Cham.Plugin.WireProtocol.{PerformRequest, CanProcessRequest, StageResult}
  alias Cham.Plugin.Events.PluginEvent
  alias Cham.PluginFixtures.FakeStage

  test "perform returns the module's result struct and forwards emit events" do
    Cham.EventBus.subscribe("plugin:fake_stage")
    req = %PerformRequest{item_id: "item-9", inputs: []}

    assert %StageResult{outcome: :produced, item_metadata: %{"title" => "Faked"}} =
             InProcess.invoke(FakeStage, req, "item-9")

    assert_receive %PluginEvent{type: :status, data: %{"message" => "working on item-9"}}
  end

  test "can_process delegates to the module's optional callback" do
    req = %CanProcessRequest{item_id: "i", inputs: [%{type: "html_capture"}]}
    assert {:ok, true} = InProcess.can_process(FakeStage, req, "i")

    empty = %CanProcessRequest{item_id: "i", inputs: []}
    assert {:ok, false} = InProcess.can_process(FakeStage, empty, "i")
  end
end
