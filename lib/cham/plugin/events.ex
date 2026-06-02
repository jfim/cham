defmodule Cham.Plugin.Events do
  @moduledoc """
  Progress events forwarded from a running plugin to the `Cham.EventBus`. These
  are *not* the result (that comes from `output.json` / the returned struct);
  they mirror v2's `ScriptOutput` live-progress forwarding.
  """

  @event_types %{"status" => :status, "progress" => :progress, "log" => :log}

  defmodule PluginEvent do
    @moduledoc "A single forwarded progress event."
    @enforce_keys [:plugin_id, :type, :data]
    defstruct [:plugin_id, :context_id, :type, :data]

    @type t :: %__MODULE__{
            plugin_id: String.t(),
            context_id: String.t() | nil,
            type: :status | :progress | :log,
            data: map()
          }
  end

  @doc "Build a `PluginEvent`. `context_id` is the item_id/subscription_id (may be nil)."
  @spec new(String.t(), String.t() | nil, :status | :progress | :log, map()) :: PluginEvent.t()
  def new(plugin_id, context_id, type, data) when type in [:status, :progress, :log] do
    %PluginEvent{plugin_id: plugin_id, context_id: context_id, type: type, data: data}
  end

  @doc "The EventBus topic for a plugin's events (fans out to the coarse `plugin` topic)."
  @spec topic(PluginEvent.t()) :: String.t()
  def topic(%PluginEvent{plugin_id: id}), do: "plugin:#{id}"

  @doc """
  Parse one stdout JSONL line into a `PluginEvent`. Returns `:ignore` for
  non-JSON lines, lines without a known `"event"`, or unknown event types
  (stdout progress is optional and best-effort; only `output.json` is authoritative).
  """
  @spec from_line(String.t(), String.t(), String.t() | nil) :: {:ok, PluginEvent.t()} | :ignore
  def from_line(line, plugin_id, context_id) do
    with {:ok, %{"event" => event} = map} <- Jason.decode(line),
         type when not is_nil(type) <- Map.get(@event_types, event) do
      {:ok, new(plugin_id, context_id, type, Map.delete(map, "event"))}
    else
      _ -> :ignore
    end
  end
end
