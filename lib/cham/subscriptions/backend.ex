defmodule Cham.Subscriptions.Backend do
  @type item :: %{
          source_item_id: String.t(),
          url: String.t(),
          title: String.t(),
          timestamp: DateTime.t() | nil
        }

  @callback id() :: atom()
  @callback name() :: String.t()
  @callback stream_pages(url :: String.t()) :: Enumerable.t()
  @callback config_schema() :: [Cham.Plugin.config_field()]

  @optional_callbacks [config_schema: 0]
end
