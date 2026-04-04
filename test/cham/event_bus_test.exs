defmodule Cham.EventBusTest do
  use ExUnit.Case, async: true

  alias Cham.EventBus

  describe "subscribe/1 and publish/2" do
    test "subscriber receives published event" do
      EventBus.subscribe("test_topic")
      EventBus.publish("test_topic", {:test_event, "hello"})
      assert_receive {:test_event, "hello"}
    end

    test "non-subscriber does not receive event" do
      EventBus.publish("other_topic", {:test_event, "hello"})
      refute_receive {:test_event, "hello"}
    end
  end

  describe "dual-topic broadcasting" do
    test "publishes to both fine-grained and coarse topic" do
      EventBus.subscribe("pipeline")
      EventBus.subscribe("pipeline:stage_completed")

      EventBus.publish("pipeline:stage_completed", {:stage_done, 1})

      assert_receive {:stage_done, 1}
      assert_receive {:stage_done, 1}
    end

    test "coarse subscriber receives events from all fine-grained topics" do
      EventBus.subscribe("pipeline")

      EventBus.publish("pipeline:stage_completed", {:completed, 1})
      EventBus.publish("pipeline:stage_failed", {:failed, 2})

      assert_receive {:completed, 1}
      assert_receive {:failed, 2}
    end

    test "topic without colon publishes once only" do
      EventBus.subscribe("simple")

      EventBus.publish("simple", {:event, 1})

      assert_receive {:event, 1}
      refute_receive {:event, 1}
    end
  end
end
