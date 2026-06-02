defmodule Cham.Subscriptions.Backend do
  @moduledoc """
  Behaviour for subscription source backends (e.g. RSS) that produce ingestable
  items, along with the shared item and config-field types.
  """
  @type item :: %{
          source_item_id: String.t(),
          url: String.t(),
          title: String.t(),
          timestamp: DateTime.t() | nil
        }

  @type config_field :: %{
          key: atom(),
          type: atom(),
          default: any(),
          description: String.t(),
          required: boolean(),
          options: [any()] | nil
        }

  @callback id() :: atom()
  @callback name() :: String.t()
  @callback stream_pages(url :: String.t()) :: Enumerable.t()
  @callback config_schema() :: [config_field()]

  @optional_callbacks [config_schema: 0]
end
