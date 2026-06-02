defmodule Cham.Plugin.Transport.Subprocess do
  @moduledoc """
  The external-subprocess transport. One-shot per invocation: writes
  `request.json` into `working_dir`, deletes any stale `output.json`, spawns the
  entrypoint with `working_dir` as its sole argument (cwd = the plugin dir),
  line-buffers stdout as JSONL progress events (forwarded to the EventBus),
  redirects stderr to a log file, and after the process exits reads
  `output.json`. Absent/unparseable `output.json` or a timeout maps to
  `failed(:error)` (catches crash/OOM/hang).
  """
  require Logger
  alias Cham.Archive.Layout
  alias Cham.Plugin.{Events, WireProtocol}
  alias Cham.Plugin.WireProtocol.{CanProcessRequest, PerformRequest, SubscriptionRequest}

  @default_timeout 300_000

  @doc """
  Invoke a subprocess plugin. The request struct determines the entrypoint
  (`perform` vs `can_process`) and how `output.json` is decoded. Options:
  `:timeout` (ms, default 5 min) and `:log_to` (stderr log path, default
  `working_dir/stage.log`).
  """
  def invoke(manifest, request, working_dir, opts \\ []) do
    working_dir = Path.expand(working_dir)
    File.mkdir_p!(working_dir)
    output_path = Path.join(working_dir, "output.json")
    File.rm(output_path)

    :ok =
      Layout.atomic_write(
        Path.join(working_dir, "request.json"),
        Jason.encode!(WireProtocol.encode_request(request))
      )

    entrypoint = entrypoint_for(request, manifest)
    log_path = Path.expand(Keyword.get(opts, :log_to, Path.join(working_dir, "stage.log")))
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    {:dir, plugin_dir} = manifest.source

    exit_status =
      run_port(
        entrypoint,
        working_dir,
        plugin_dir,
        log_path,
        timeout,
        manifest.id,
        context_id(request)
      )

    decode_result(request, output_path, exit_status)
  end

  defp entrypoint_for(%CanProcessRequest{}, manifest), do: manifest.entrypoints.can_process
  defp entrypoint_for(_perform, manifest), do: manifest.entrypoints.perform

  defp context_id(%PerformRequest{item_id: id}), do: id
  defp context_id(%CanProcessRequest{item_id: id}), do: id
  defp context_id(%SubscriptionRequest{subscription_id: id}), do: id

  # Spawn `sh -c 'exec <entrypoint> "$1" 2> "$2"' sh <working_dir> <log_path>`,
  # line-buffering stdout. The entrypoint string comes from the trusted on-disk
  # manifest (operator-authored), not remote input.
  defp run_port(entrypoint, working_dir, plugin_dir, log_path, timeout, plugin_id, context_id) do
    sh = System.find_executable("sh")
    script = "exec #{entrypoint} \"$1\" 2> \"$2\""

    File.mkdir_p!(Path.dirname(log_path))

    port =
      Port.open(
        {:spawn_executable, sh},
        [
          :binary,
          :exit_status,
          {:line, 65_536},
          cd: plugin_dir,
          args: ["-c", script, "sh", working_dir, log_path]
        ]
      )

    collect(port, timeout, plugin_id, context_id, "")
  end

  defp collect(port, timeout, plugin_id, context_id, buffer) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        forward(buffer <> chunk, plugin_id, context_id)
        collect(port, timeout, plugin_id, context_id, "")

      {^port, {:data, {:noeol, chunk}}} ->
        collect(port, timeout, plugin_id, context_id, buffer <> chunk)

      {^port, {:exit_status, status}} ->
        {:exited, status}
    after
      timeout ->
        kill_port(port)
        :timeout
    end
  end

  defp forward(line, plugin_id, context_id) do
    case Events.from_line(line, plugin_id, context_id) do
      {:ok, event} -> Cham.EventBus.publish(Events.topic(event), event)
      :ignore -> :ok
    end
  end

  defp kill_port(port) do
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    Port.close(port)
    System.cmd("kill", ["-9", "#{os_pid}"])
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp decode_result(%CanProcessRequest{}, output_path, status) do
    with {:exited, _} <- status,
         {:ok, body} <- File.read(output_path),
         {:ok, json} <- Jason.decode(body),
         {:ok, applicable} <- WireProtocol.decode_probe(json) do
      {:ok, applicable}
    else
      _ -> {:error, :crashed}
    end
  end

  defp decode_result(%SubscriptionRequest{}, output_path, status) do
    with {:exited, _} <- status,
         {:ok, body} <- File.read(output_path),
         {:ok, json} <- Jason.decode(body),
         {:ok, result} <- WireProtocol.decode_subscription_result(json) do
      result
    else
      _ -> {:error, :crashed}
    end
  end

  defp decode_result(%PerformRequest{}, output_path, status) do
    with {:exited, _} <- status,
         {:ok, body} <- File.read(output_path),
         {:ok, json} <- Jason.decode(body),
         {:ok, result} <- WireProtocol.decode_stage_result(json) do
      result
    else
      other ->
        Logger.warning("subprocess perform produced no valid output.json (#{inspect(other)})")
        %WireProtocol.StageResult{outcome: :failed, category: :error}
    end
  end
end
