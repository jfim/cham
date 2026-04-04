defmodule Cham.Plugin.Registry do
  @moduledoc """
  GenServer that maintains the ordered list of loaded plugins, their state,
  and collects stages from all plugins.
  """

  use GenServer
  require Logger

  defmodule PluginEntry do
    @moduledoc false
    defstruct [:plugin_id, :name, :description, :module, :state, :config_schema]
  end

  defmodule StageEntry do
    @moduledoc false
    defstruct [:module, :plugin_id, :input_matchers, :output_labels, :queue, :max_attempts]
  end

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def register_plugin(server \\ __MODULE__, plugin_module, config) do
    GenServer.call(server, {:register_plugin, plugin_module, config})
  end

  def list_plugins(server \\ __MODULE__) do
    GenServer.call(server, :list_plugins)
  end

  def get_plugin(server \\ __MODULE__, plugin_id) do
    GenServer.call(server, {:get_plugin, plugin_id})
  end

  def get_stages(server \\ __MODULE__) do
    GenServer.call(server, :get_stages)
  end

  @impl true
  def init(opts) do
    plugin_order = Keyword.get(opts, :plugin_order, [])
    {:ok, %{plugins: %{}, plugin_order: plugin_order}}
  end

  @impl true
  def handle_call({:register_plugin, plugin_module, config}, _from, state) do
    plugin_id = plugin_module.plugin_id()

    if Map.has_key?(state.plugins, plugin_id) do
      {:reply, {:error, :already_registered}, state}
    else
      context = %{plugin_dir: "", config: config}

      case plugin_module.init(context) do
        {:ok, plugin_state} ->
          entry = %PluginEntry{
            plugin_id: plugin_id,
            name: plugin_module.name(),
            description: plugin_module.description(),
            module: plugin_module,
            state: plugin_state,
            config_schema: plugin_module.config_schema()
          }

          new_plugins = Map.put(state.plugins, plugin_id, entry)
          {:reply, :ok, %{state | plugins: new_plugins}}

        {:error, reason} ->
          Logger.warning("Plugin #{plugin_id} failed to init: #{inspect(reason)}")
          {:reply, {:error, reason}, state}
      end
    end
  end

  @impl true
  def handle_call(:list_plugins, _from, state) do
    {:reply, order_plugins(state.plugins, state.plugin_order), state}
  end

  @impl true
  def handle_call({:get_plugin, plugin_id}, _from, state) do
    case Map.get(state.plugins, plugin_id) do
      nil -> {:reply, {:error, :not_found}, state}
      entry -> {:reply, {:ok, entry}, state}
    end
  end

  @impl true
  def handle_call(:get_stages, _from, state) do
    stages =
      state.plugins
      |> order_plugins(state.plugin_order)
      |> Enum.flat_map(fn entry ->
        stage_modules = entry.module.stages(entry.state)

        Enum.map(stage_modules, fn mod ->
          %StageEntry{
            module: mod,
            plugin_id: entry.plugin_id,
            input_matchers:
              if(function_exported?(mod, :input_matchers, 0), do: mod.input_matchers(), else: []),
            output_labels:
              if(function_exported?(mod, :output_labels, 0), do: mod.output_labels(), else: []),
            queue: mod.queue(),
            max_attempts: mod.max_attempts()
          }
        end)
      end)

    {:reply, stages, state}
  end

  defp order_plugins(plugins_map, plugin_order) do
    known_ids = MapSet.new(plugin_order)
    all_entries = Map.values(plugins_map)

    ordered =
      plugin_order
      |> Enum.filter(&Map.has_key?(plugins_map, &1))
      |> Enum.map(&Map.get(plugins_map, &1))

    unordered =
      all_entries
      |> Enum.reject(&MapSet.member?(known_ids, &1.plugin_id))
      |> Enum.sort_by(& &1.plugin_id)

    ordered ++ unordered
  end
end
