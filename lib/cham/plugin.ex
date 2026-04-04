defmodule Cham.Plugin do
  @type config_field :: %{
          key: atom(),
          type: atom(),
          default: any(),
          description: String.t(),
          required: boolean(),
          options: [any()] | nil
        }

  @callback plugin_id() :: String.t()
  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback config_schema() :: [config_field()]
  @callback init(context :: map()) :: {:ok, state :: map()} | {:error, reason :: String.t()}
  @callback stages(state :: map()) :: [module()]
end
