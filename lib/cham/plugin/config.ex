defmodule Cham.Plugin.Config do
  @moduledoc """
  Helper for reading plugin configuration from the Config.Manager.
  Falls back to schema defaults if the Config.Manager is unavailable
  or the namespace isn't registered.
  """

  @doc """
  Read config for a plugin. Tries Config.Manager first (which applies
  schema validation and defaults), falls back to extracting defaults
  from the plugin's config_schema.
  """
  def read(plugin_id) do
    namespace = "plugins.#{plugin_id}"

    case Cham.Config.Manager.read_all(namespace) do
      {:ok, values} ->
        values

      {:error, _} ->
        # Config.Manager not available or namespace not registered —
        # fall back to schema defaults from the registry
        case Cham.Plugin.Registry.get_plugin(plugin_id) do
          {:ok, entry} ->
            entry.config_schema
            |> Enum.map(fn field -> {field.key, field.default} end)
            |> Map.new()

          _ ->
            %{}
        end
    end
  end
end
