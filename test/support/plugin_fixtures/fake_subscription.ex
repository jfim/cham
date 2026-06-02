defmodule Cham.PluginFixtures.FakeSubscription do
  @moduledoc false
  @behaviour Cham.Plugin.Subscription
  alias Cham.Plugin.{Manifest, WireProtocol}

  @impl true
  def manifest do
    %Manifest{
      id: "fake_subscription",
      kind: :subscription,
      class: :in_process,
      source: {:module, __MODULE__}
    }
  end

  @impl true
  def perform(%WireProtocol.SubscriptionRequest{checkpoint: checkpoint}, _emit) do
    case checkpoint do
      nil ->
        %WireProtocol.SubscriptionResult{
          items: [%{"url" => "https://x/1", "metadata" => %{}}],
          checkpoint: "v1"
        }

      other ->
        # Recognizes the checkpoint it issued and reports nothing new (round-trip).
        %WireProtocol.SubscriptionResult{items: [], checkpoint: other}
    end
  end
end
