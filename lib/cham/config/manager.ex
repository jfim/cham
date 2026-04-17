defmodule Cham.Config.Manager do
  use GenServer
  require Logger

  alias Cham.Config.{Schema, TomlEncoder}
  alias Cham.Config.Events.ConfigChanged

  # --- Client API ---

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def register(server \\ __MODULE__, namespace, schema) do
    GenServer.call(server, {:register, namespace, schema})
  end

  def read_all(server \\ __MODULE__, namespace) do
    GenServer.call(server, {:read_all, namespace})
  end

  def write_all(server \\ __MODULE__, namespace, values) do
    GenServer.call(server, {:write_all, namespace, values})
  end

  def list_schemas(server \\ __MODULE__) do
    GenServer.call(server, :list_schemas)
  end

  # --- Server ---

  @impl true
  def init(opts) do
    toml_path = Keyword.fetch!(opts, :toml_path)
    event_bus = Keyword.get(opts, :event_bus)

    raw =
      if File.exists?(toml_path) do
        case Toml.decode_file(toml_path) do
          {:ok, parsed} ->
            parsed

          {:error, reason} ->
            Logger.error(
              "Failed to parse TOML config at #{toml_path}: #{inspect(reason)}. Using empty config."
            )

            %{}
        end
      else
        %{}
      end

    {:ok, %{schemas: %{}, raw: raw, toml_path: toml_path, event_bus: event_bus}}
  end

  @impl true
  def handle_call({:register, namespace, schema}, _from, state) do
    if Map.has_key?(state.schemas, namespace) do
      {:reply, {:error, :already_registered}, state}
    else
      {:reply, :ok, put_in(state.schemas[namespace], schema)}
    end
  end

  def handle_call({:read_all, namespace}, _from, state) do
    case Map.get(state.schemas, namespace) do
      nil ->
        {:reply, {:error, :unknown_namespace}, state}

      schema ->
        raw_values = get_nested(state.raw, namespace)
        {:reply, Schema.validate(raw_values, schema), state}
    end
  end

  def handle_call({:write_all, namespace, values}, _from, state) do
    case Map.get(state.schemas, namespace) do
      nil ->
        {:reply, {:error, :unknown_namespace}, state}

      schema ->
        string_values =
          values
          |> Enum.into(%{}, fn {k, v} -> {Atom.to_string(k), v} end)

        merged = Map.merge(Map.get(state.raw, namespace, %{}), string_values)

        case Schema.validate(merged, schema) do
          {:ok, _validated} ->
            new_raw = Map.put(state.raw, namespace, merged)
            write_toml_file(state.toml_path, new_raw)
            publish_change(state.event_bus, namespace, values)
            {:reply, :ok, %{state | raw: new_raw}}

          {:error, errors} ->
            {:reply, {:error, errors}, state}
        end
    end
  end

  def handle_call(:list_schemas, _from, state) do
    {:reply, Enum.to_list(state.schemas), state}
  end

  # --- Private ---

  defp get_nested(raw, namespace) do
    keys = String.split(namespace, ".")

    Enum.reduce_while(keys, raw, fn key, acc ->
      case acc do
        %{} -> {:cont, Map.get(acc, key, %{})}
        _ -> {:halt, %{}}
      end
    end)
  end

  defp write_toml_file(path, raw) do
    content = TomlEncoder.encode(raw)
    tmp_path = path <> ".tmp"
    File.mkdir_p!(Path.dirname(path))
    File.write!(tmp_path, content)
    File.rename!(tmp_path, path)
  end

  defp publish_change(nil, _namespace, _values), do: :ok

  defp publish_change(_pubsub, namespace, values) do
    event = %ConfigChanged{namespace: namespace, values: values}
    Cham.EventBus.publish("config:#{namespace}", event)
  end
end
