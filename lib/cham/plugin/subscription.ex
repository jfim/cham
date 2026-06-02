defmodule Cham.Plugin.Subscription do
  @moduledoc """
  Behaviour for an in-process subscription plugin. `perform/2` is handed the
  opaque checkpoint inside the request and returns a
  `Cham.Plugin.WireProtocol.SubscriptionResult` ({items, new checkpoint}).
  """
  alias Cham.Plugin.{Manifest, WireProtocol}

  @callback manifest() :: Manifest.t()
  @callback perform(WireProtocol.SubscriptionRequest.t(), emit :: (map() -> :ok)) ::
              WireProtocol.SubscriptionResult.t()
end
