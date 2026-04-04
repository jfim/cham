defmodule Cham.EventBus do
  @pubsub Cham.PubSub

  @doc """
  Subscribe the calling process to a topic.
  """
  def subscribe(topic) do
    Phoenix.PubSub.subscribe(@pubsub, topic)
  end

  @doc """
  Publish an event to a topic. If the topic contains a colon (e.g. "pipeline:stage_completed"),
  the event is also broadcast to the coarse topic (e.g. "pipeline").
  """
  def publish(topic, event) do
    Phoenix.PubSub.broadcast(@pubsub, topic, event)

    case String.split(topic, ":", parts: 2) do
      [coarse, _fine] -> Phoenix.PubSub.broadcast(@pubsub, coarse, event)
      [_single] -> :ok
    end

    :ok
  end
end
