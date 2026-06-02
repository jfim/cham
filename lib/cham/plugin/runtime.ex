defmodule Cham.Plugin.Runtime do
  @moduledoc """
  The unified plugin-invocation entry point. Looks a plugin up in the registry
  and dispatches to the in-process or subprocess transport purely on the
  plugin's `class` — the caller (and, later, `plan`) never knows which. This is
  the seam Phase 4's executor invokes.
  """
  alias Cham.Plugin.Registry
  alias Cham.Plugin.Transport.{InProcess, Subprocess}
  alias Cham.Plugin.WireProtocol.{CanProcessRequest, PerformRequest, SubscriptionRequest}

  @doc """
  Invoke a plugin by id with a request struct. `working_dir` is the subprocess
  invocation's working directory (created if needed; ignored by the in-process
  transport). Options: `:registry` (server, default `Cham.Plugin.Registry`),
  `:timeout`, `:log_to` (subprocess only).
  """
  def run(plugin_id, request, working_dir, opts \\ []) do
    registry = Keyword.get(opts, :registry, Registry)

    case Registry.lookup(registry, plugin_id) do
      {:ok, manifest} -> dispatch(manifest, request, working_dir, opts)
      :error -> {:error, :unknown_plugin}
    end
  end

  defp dispatch(%{class: :in_process, source: {:module, module}}, request, _working_dir, _opts) do
    case request do
      %CanProcessRequest{} -> InProcess.can_process(module, request, context_id(request))
      _ -> InProcess.invoke(module, request, context_id(request))
    end
  end

  defp dispatch(%{class: :subprocess} = manifest, request, working_dir, opts) do
    Subprocess.invoke(manifest, request, working_dir, Keyword.take(opts, [:timeout, :log_to]))
  end

  defp context_id(%PerformRequest{item_id: id}), do: id
  defp context_id(%CanProcessRequest{item_id: id}), do: id
  defp context_id(%SubscriptionRequest{subscription_id: id}), do: id
end
