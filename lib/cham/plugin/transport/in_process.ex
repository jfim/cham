defmodule Cham.Plugin.Transport.InProcess do
  @moduledoc """
  The in-process (fast-path) transport. Invokes an Elixir behaviour module
  directly: builds an `emit` closure that publishes `PluginEvent`s to the
  EventBus, calls the module, and returns the result struct verbatim. No
  serialization, no port, no files.
  """
  alias Cham.Plugin.Events
  alias Cham.Plugin.WireProtocol.{CanProcessRequest, PerformRequest, SubscriptionRequest}

  @doc "Invoke `perform/2` on `module` with `request`; returns the result struct."
  def invoke(module, %struct{} = request, context_id)
      when struct in [PerformRequest, SubscriptionRequest] do
    emit = build_emit(module_id(module), context_id)
    module.perform(request, emit)
  end

  @doc "Invoke the optional `can_process/1`; `{:ok, boolean}` or `{:error, :no_probe}`."
  def can_process(module, %CanProcessRequest{} = request, _context_id) do
    Code.ensure_loaded!(module)

    if function_exported?(module, :can_process, 1) do
      {:ok, module.can_process(request)}
    else
      {:error, :no_probe}
    end
  end

  defp build_emit(plugin_id, context_id) do
    fn raw ->
      data = normalize(raw)

      with %{"event" => event} <- data,
           type when not is_nil(type) <- event_type(event) do
        ev = Events.new(plugin_id, context_id, type, Map.delete(data, "event"))
        Cham.EventBus.publish(Events.topic(ev), ev)
      else
        _ -> :ok
      end

      :ok
    end
  end

  defp event_type("status"), do: :status
  defp event_type("progress"), do: :progress
  defp event_type("log"), do: :log
  defp event_type(_), do: nil

  defp normalize(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp module_id(module), do: module.manifest().id
end
