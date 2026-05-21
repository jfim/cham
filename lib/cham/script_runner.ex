defmodule Cham.ScriptRunner do
  alias Cham.ScriptRunner.Events.{ScriptExited, ScriptOutput, ScriptTimeout}

  def run_sync(command, args, opts) do
    timeout = Keyword.fetch!(opts, :timeout)
    log_to = Keyword.get(opts, :log_to)

    port =
      Port.open(
        {:spawn_executable, System.find_executable(command)},
        [:binary, :exit_status, :stderr_to_stdout, args: args]
      )

    result = collect_output(port, timeout, [])

    case result do
      {:ok, output, exit_code} ->
        if log_to, do: write_log(log_to, output)
        {:ok, output, "", exit_code}

      {:error, :timeout, output} ->
        if log_to, do: write_log(log_to, output)
        kill_port(port)
        {:error, :timeout, output, ""}
    end
  end

  def run_async(command, args, opts) do
    timeout = Keyword.fetch!(opts, :timeout)
    log_to = Keyword.get(opts, :log_to)
    ref = make_ref()

    topic = "script:#{inspect(ref)}"
    Cham.EventBus.subscribe(topic)

    spawn(fn ->
      port =
        Port.open(
          {:spawn_executable, System.find_executable(command)},
          [:binary, :exit_status, :stderr_to_stdout, args: args]
        )

      async_collect(port, ref, topic, timeout, log_to, [])
    end)

    {:ok, ref}
  end

  def run_script_sync(script_dir, args, opts) do
    scripts_path = Keyword.get(opts, :scripts_path, "scripts")
    script_path = Path.join([scripts_path, script_dir, "main.py"])
    clean_opts = Keyword.drop(opts, [:scripts_path])
    run_sync("uv", ["run", script_path | args], clean_opts)
  end

  def run_script_async(script_dir, args, opts) do
    scripts_path = Keyword.get(opts, :scripts_path, "scripts")
    script_path = Path.join([scripts_path, script_dir, "main.py"])
    clean_opts = Keyword.drop(opts, [:scripts_path])
    run_async("uv", ["run", script_path | args], clean_opts)
  end

  # --- Private ---

  defp collect_output(port, timeout, acc) do
    receive do
      {^port, {:data, data}} ->
        collect_output(port, timeout, [data | acc])

      {^port, {:exit_status, exit_code}} ->
        output = acc |> Enum.reverse() |> IO.iodata_to_binary()
        {:ok, output, exit_code}
    after
      timeout ->
        output = acc |> Enum.reverse() |> IO.iodata_to_binary()
        {:error, :timeout, output}
    end
  end

  defp async_collect(port, ref, topic, timeout, log_to, acc) do
    receive do
      {^port, {:data, data}} ->
        Cham.EventBus.publish(topic, %ScriptOutput{ref: ref, data: data})
        async_collect(port, ref, topic, timeout, log_to, [data | acc])

      {^port, {:exit_status, exit_code}} ->
        if log_to, do: write_log(log_to, acc |> Enum.reverse() |> IO.iodata_to_binary())
        Cham.EventBus.publish(topic, %ScriptExited{ref: ref, exit_code: exit_code})
    after
      timeout ->
        if log_to, do: write_log(log_to, acc |> Enum.reverse() |> IO.iodata_to_binary())
        kill_port(port)
        Cham.EventBus.publish(topic, %ScriptTimeout{ref: ref})
    end
  end

  defp kill_port(port) do
    try do
      {:os_pid, os_pid} = Port.info(port, :os_pid)
      Port.close(port)
      System.cmd("kill", ["-9", "#{os_pid}"])
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  defp write_log(path, content) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end
end
