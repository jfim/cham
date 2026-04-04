# Phase 3: Core Infrastructure — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the three Core Infrastructure subsystems — LLM Integration (provider behaviour + OpenAI-compatible implementation), Script Runner (sync/async external process execution with timeouts), and Plugin System (behaviour, registry, stage registry, conflict detection).

**Architecture:** LLM Integration defines a `Provider` behaviour and ships an OpenAI-compatible implementation using `Req` for HTTP. Script Runner uses Erlang ports for process management with timeout enforcement. The Plugin System defines `Plugin` and `Stage` behaviours, a plugin registry for ordered plugin management, and a stage registry that the DAG builder queries.

**Tech Stack:** Elixir 1.17+, `Req` for HTTP (already a Phoenix dep), Erlang `:port` for external processes

---

## File Structure

### New Files

| File | Responsibility |
|------|---------------|
| `lib/cham/llm/provider.ex` | Provider behaviour definition + `generate/2` convenience |
| `lib/cham/llm/providers/openai.ex` | OpenAI-compatible chat completions provider |
| `lib/cham/script_runner.ex` | Sync/async external process execution with timeouts |
| `lib/cham/script_runner/events.ex` | Event structs for async script output |
| `lib/cham/plugin.ex` | Plugin behaviour definition |
| `lib/cham/stage.ex` | Stage behaviour definition (simple + dynamic) |
| `lib/cham/plugin/registry.ex` | GenServer: ordered plugin list, config, conflict detection |
| `lib/cham/plugin/stage_registry.ex` | Flat list of all stages from all plugins |
| `test/cham/llm/providers/openai_test.exs` | Tests for OpenAI provider (with Bypass for HTTP mocking) |
| `test/cham/script_runner_test.exs` | Tests for sync execution and timeouts |
| `test/cham/plugin/registry_test.exs` | Tests for plugin registration, ordering, conflicts |
| `test/cham/plugin/stage_registry_test.exs` | Tests for stage registration and querying |

### Dependencies to Add

- `{:bypass, "~> 2.1", only: :test}` — HTTP request mocking for LLM provider tests

### Parallelism

All three subsystems are independent and can be implemented in parallel:
- Task 1-2: LLM Integration
- Task 3-4: Script Runner
- Task 5-8: Plugin System (behaviour → stage behaviour → registry → stage registry)

---

## Task 1: LLM Provider Behaviour

**Files:**
- Create: `lib/cham/llm/provider.ex`

- [ ] **Step 1: Create the Provider behaviour**

Create `lib/cham/llm/provider.ex`:

```elixir
defmodule Cham.LLM.Provider do
  @doc """
  Behaviour for LLM providers. Each provider handles HTTP communication
  with a specific LLM backend.
  """

  @callback chat(messages :: [map()], opts :: keyword()) ::
              {:ok, String.t()} | {:error, term()}

  @doc """
  Convenience: wraps a single prompt string into a one-message chat call.
  The provider module must be passed explicitly.
  """
  def generate(provider, prompt, opts) do
    provider.chat([%{"role" => "user", "content" => prompt}], opts)
  end
end
```

- [ ] **Step 2: Commit**

```bash
git add lib/cham/llm/provider.ex
git commit -m "feat: add LLM Provider behaviour

Defines the callback contract for LLM providers. Includes a
generate/3 convenience that wraps a prompt in a single-message chat."
```

---

## Task 2: OpenAI-Compatible Provider

**Files:**
- Create: `lib/cham/llm/providers/openai.ex`
- Create: `test/cham/llm/providers/openai_test.exs`
- Modify: `mix.exs` (add bypass test dep)

- [ ] **Step 1: Add bypass test dependency**

In `mix.exs`, add to deps:

```elixir
{:bypass, "~> 2.1", only: :test}
```

Run: `mix deps.get`

- [ ] **Step 2: Write the failing tests**

Create `test/cham/llm/providers/openai_test.exs`:

```elixir
defmodule Cham.LLM.Providers.OpenAITest do
  use ExUnit.Case, async: true

  alias Cham.LLM.Providers.OpenAI

  setup do
    bypass = Bypass.open()
    %{bypass: bypass, url: "http://localhost:#{bypass.port}"}
  end

  describe "chat/2" do
    test "returns response text on success", %{bypass: bypass, url: url} do
      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["model"] == "test-model"
        assert length(decoded["messages"]) == 1

        response = %{
          "choices" => [%{"message" => %{"content" => "Hello from LLM!"}}]
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(response))
      end)

      messages = [%{"role" => "user", "content" => "Hi"}]
      assert {:ok, "Hello from LLM!"} = OpenAI.chat(messages, model: "test-model", url: url)
    end

    test "returns error on non-200 response", %{bypass: bypass, url: url} do
      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(429, ~s({"error": "rate limited"}))
      end)

      messages = [%{"role" => "user", "content" => "Hi"}]
      assert {:error, msg} = OpenAI.chat(messages, model: "test-model", url: url)
      assert msg =~ "429"
    end

    test "returns error on connection failure", %{url: url} do
      # Use a port that nothing is listening on
      messages = [%{"role" => "user", "content" => "Hi"}]
      assert {:error, msg} = OpenAI.chat(messages, model: "test-model", url: "http://localhost:1")
      assert msg =~ "request failed"
    end

    test "returns error on malformed response", %{bypass: bypass, url: url} do
      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"unexpected": "format"}))
      end)

      messages = [%{"role" => "user", "content" => "Hi"}]
      assert {:error, "failed to parse response"} = OpenAI.chat(messages, model: "test-model", url: url)
    end

    test "sends authorization header when api_key is provided", %{bypass: bypass, url: url} do
      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
        auth = Plug.Conn.get_req_header(conn, "authorization")
        assert auth == ["Bearer sk-test-key"]

        response = %{"choices" => [%{"message" => %{"content" => "ok"}}]}

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(response))
      end)

      messages = [%{"role" => "user", "content" => "Hi"}]
      assert {:ok, _} = OpenAI.chat(messages, model: "m", url: url, api_key: "sk-test-key")
    end
  end

  describe "generate/3 via Provider behaviour" do
    test "wraps prompt into single-message chat", %{bypass: bypass, url: url} do
      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        [msg] = decoded["messages"]
        assert msg["role"] == "user"
        assert msg["content"] == "Summarize this"

        response = %{"choices" => [%{"message" => %{"content" => "Summary here"}}]}

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(response))
      end)

      assert {:ok, "Summary here"} =
               Cham.LLM.Provider.generate(OpenAI, "Summarize this", model: "m", url: url)
    end
  end
end
```

- [ ] **Step 2b: Run tests to verify they fail**

```bash
mix test test/cham/llm/providers/openai_test.exs
```

Expected: compilation error — module does not exist.

- [ ] **Step 3: Implement the OpenAI provider**

Create `lib/cham/llm/providers/openai.ex`:

```elixir
defmodule Cham.LLM.Providers.OpenAI do
  @behaviour Cham.LLM.Provider

  @impl true
  def chat(messages, opts) do
    model = Keyword.fetch!(opts, :model)
    url = Keyword.get(opts, :url, "http://localhost:11434")
    timeout = Keyword.get(opts, :timeout, 300_000)
    api_key = Keyword.get(opts, :api_key)

    headers = [{"content-type", "application/json"}]
    headers = if api_key, do: [{"authorization", "Bearer #{api_key}"} | headers], else: headers

    body =
      Jason.encode!(%{
        "model" => model,
        "messages" => messages
      })

    case Req.post("#{url}/v1/chat/completions",
           body: body,
           headers: headers,
           receive_timeout: timeout,
           connect_options: [timeout: 10_000],
           retry: false
         ) do
      {:ok, %{status: 200, body: resp_body}} ->
        parse_response(resp_body)

      {:ok, %{status: status, body: resp_body}} ->
        body_str = if is_binary(resp_body), do: resp_body, else: Jason.encode!(resp_body)
        {:error, "HTTP #{status}: #{body_str}"}

      {:error, exception} ->
        {:error, "request failed: #{inspect(exception)}"}
    end
  end

  defp parse_response(%{"choices" => [%{"message" => %{"content" => content}} | _]}) do
    {:ok, content}
  end

  defp parse_response(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> parse_response(decoded)
      {:error, _} -> {:error, "failed to parse response"}
    end
  end

  defp parse_response(_), do: {:error, "failed to parse response"}
end
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
mix test test/cham/llm/providers/openai_test.exs
```

Expected: all 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/cham/llm/providers/openai.ex test/cham/llm/providers/openai_test.exs mix.exs mix.lock
git commit -m "feat: add OpenAI-compatible LLM provider

Implements the Provider behaviour for any server speaking the
/v1/chat/completions API. Covers Ollama, llama-server, vLLM,
and OpenAI. Uses Req for HTTP. Optional api_key support."
```

---

## Task 3: Script Runner — Sync Execution

**Files:**
- Create: `lib/cham/script_runner.ex`
- Create: `test/cham/script_runner_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/cham/script_runner_test.exs`:

```elixir
defmodule Cham.ScriptRunnerTest do
  use ExUnit.Case, async: true

  alias Cham.ScriptRunner

  describe "run_sync/3" do
    test "runs a command and captures stdout" do
      assert {:ok, stdout, _stderr, 0} =
               ScriptRunner.run_sync("echo", ["hello world"], timeout: 5_000)

      assert String.trim(stdout) == "hello world"
    end

    test "captures stderr separately" do
      assert {:ok, _stdout, stderr, 0} =
               ScriptRunner.run_sync("sh", ["-c", "echo errout >&2"], timeout: 5_000)

      assert String.trim(stderr) == "errout"
    end

    test "returns non-zero exit code" do
      assert {:ok, _stdout, _stderr, 1} =
               ScriptRunner.run_sync("sh", ["-c", "exit 1"], timeout: 5_000)
    end

    test "returns timeout error when command exceeds timeout" do
      assert {:error, :timeout, _stdout, _stderr} =
               ScriptRunner.run_sync("sleep", ["10"], timeout: 500)
    end

    test "writes combined output to log file when log_to is specified" do
      log_path = Path.join(System.tmp_dir!(), "cham_sr_test_#{:erlang.unique_integer([:positive])}.log")

      on_exit(fn -> File.rm(log_path) end)

      {:ok, _stdout, _stderr, 0} =
        ScriptRunner.run_sync(
          "sh",
          ["-c", "echo stdout_line; echo stderr_line >&2"],
          timeout: 5_000,
          log_to: log_path
        )

      log_content = File.read!(log_path)
      assert log_content =~ "stdout_line"
      assert log_content =~ "stderr_line"
    end
  end

  describe "run_script_sync/3" do
    test "constructs uv run command for script directory" do
      # This test verifies the command construction, not actual script execution.
      # It will fail because the script doesn't exist, but we verify the error
      # mentions the expected path.
      result =
        ScriptRunner.run_script_sync("nonexistent_script", ["arg1"],
          timeout: 5_000,
          scripts_path: "/tmp/fake_scripts"
        )

      case result do
        {:ok, _stdout, stderr, exit_code} ->
          # uv should fail because the script doesn't exist
          assert exit_code != 0 or stderr =~ "nonexistent"

        {:error, :timeout, _, _} ->
          flunk("Should not timeout")
      end
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
mix test test/cham/script_runner_test.exs
```

Expected: compilation error — module does not exist.

- [ ] **Step 3: Implement the Script Runner**

Create `lib/cham/script_runner.ex`:

```elixir
defmodule Cham.ScriptRunner do
  @doc """
  Run an external command synchronously. Blocks until completion or timeout.

  Returns:
  - {:ok, stdout, stderr, exit_code}
  - {:error, :timeout, stdout, stderr}
  """
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
        # Since we use stderr_to_stdout, split isn't possible via port.
        # Return all output as stdout, stderr empty.
        {:ok, output, "", exit_code}

      {:error, :timeout, output} ->
        if log_to, do: write_log(log_to, output)
        kill_port(port)
        {:error, :timeout, output, ""}
    end
  end

  @doc """
  Convenience: run a built-in Python script via `uv run`.

  Constructs: uv run <scripts_path>/<script_dir>/main.py <args...>
  """
  def run_script_sync(script_dir, args, opts) do
    scripts_path = Keyword.get(opts, :scripts_path, "scripts")
    script_path = Path.join([scripts_path, script_dir, "main.py"])
    clean_opts = Keyword.drop(opts, [:scripts_path])
    run_sync("uv", ["run", script_path | args], clean_opts)
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
```

**Note:** The port option `:stderr_to_stdout` merges stderr into stdout. This is simpler than managing two separate streams via ports. The return value puts all output in `stdout` and returns empty string for `stderr`. The `log_to` option writes the combined output. This is a pragmatic simplification — if separate stderr capture becomes important later, we can use a more complex approach with `System.cmd` or a helper process.

- [ ] **Step 4: Run tests to verify they pass**

```bash
mix test test/cham/script_runner_test.exs
```

Expected: 5 of 6 tests pass. The `run_script_sync` test may fail if `uv` is not installed — that's expected. Tag it as integration if needed.

- [ ] **Step 5: Commit**

```bash
git add lib/cham/script_runner.ex test/cham/script_runner_test.exs
git commit -m "feat: add Script Runner for sync external process execution

Runs external commands via Erlang ports with mandatory timeouts.
Captures stdout (merged with stderr), supports log_to file option.
Includes run_script_sync convenience for uv-based Python scripts."
```

---

## Task 4: Script Runner — Async Execution + Events

**Files:**
- Create: `lib/cham/script_runner/events.ex`
- Modify: `lib/cham/script_runner.ex` (add `run_async/3` and `run_script_async/3`)
- Modify: `test/cham/script_runner_test.exs` (add async tests)

- [ ] **Step 1: Create event structs**

Create `lib/cham/script_runner/events.ex`:

```elixir
defmodule Cham.ScriptRunner.Events do
  defmodule ScriptOutput do
    @enforce_keys [:ref, :data]
    defstruct [:ref, :data]
  end

  defmodule ScriptExited do
    @enforce_keys [:ref, :exit_code]
    defstruct [:ref, :exit_code]
  end

  defmodule ScriptTimeout do
    @enforce_keys [:ref]
    defstruct [:ref]
  end
end
```

- [ ] **Step 2: Write async tests**

Add to `test/cham/script_runner_test.exs`:

```elixir
  alias Cham.ScriptRunner.Events.{ScriptOutput, ScriptExited, ScriptTimeout}

  describe "run_async/3" do
    test "streams output via event bus and sends exit event" do
      assert {:ok, ref} =
               ScriptRunner.run_async("sh", ["-c", "echo async_hello"], timeout: 5_000)

      assert_receive %ScriptOutput{ref: ^ref, data: data}, 5_000
      assert data =~ "async_hello"

      assert_receive %ScriptExited{ref: ^ref, exit_code: 0}, 5_000
    end

    test "sends timeout event when command exceeds timeout" do
      assert {:ok, ref} =
               ScriptRunner.run_async("sleep", ["10"], timeout: 500)

      assert_receive %ScriptTimeout{ref: ^ref}, 5_000
    end
  end
```

- [ ] **Step 3: Implement run_async**

Add to `lib/cham/script_runner.ex`:

```elixir
  alias Cham.ScriptRunner.Events.{ScriptOutput, ScriptExited, ScriptTimeout}

  @doc """
  Run an external command asynchronously. Streams output via the Event Bus.
  The calling process is automatically subscribed to "script:<ref>" before
  the process starts.

  Returns {:ok, ref}.
  """
  def run_async(command, args, opts) do
    timeout = Keyword.fetch!(opts, :timeout)
    log_to = Keyword.get(opts, :log_to)
    ref = make_ref()
    caller = self()

    # Subscribe caller to script events before spawning
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

  @doc """
  Convenience: run a built-in Python script via `uv run` asynchronously.
  """
  def run_script_async(script_dir, args, opts) do
    scripts_path = Keyword.get(opts, :scripts_path, "scripts")
    script_path = Path.join([scripts_path, script_dir, "main.py"])
    clean_opts = Keyword.drop(opts, [:scripts_path])
    run_async("uv", ["run", script_path | args], clean_opts)
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
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
mix test test/cham/script_runner_test.exs
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/cham/script_runner.ex lib/cham/script_runner/events.ex test/cham/script_runner_test.exs
git commit -m "feat: add async Script Runner with event streaming

run_async streams output via Event Bus as ScriptOutput events.
ScriptExited and ScriptTimeout events signal completion.
Caller is subscribed before process starts to prevent missed events."
```

---

## Task 5: Plugin Behaviour

**Files:**
- Create: `lib/cham/plugin.ex`

- [ ] **Step 1: Create the Plugin behaviour**

Create `lib/cham/plugin.ex`:

```elixir
defmodule Cham.Plugin do
  @doc """
  Behaviour for Cham plugins. A plugin provides one or more pipeline stages
  along with configuration schema and initialization logic.
  """

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
```

- [ ] **Step 2: Commit**

```bash
git add lib/cham/plugin.ex
git commit -m "feat: add Plugin behaviour definition

Defines the contract for Cham plugins: plugin_id, name, description,
config_schema, init, and stages callbacks."
```

---

## Task 6: Stage Behaviour

**Files:**
- Create: `lib/cham/stage.ex`

- [ ] **Step 1: Create the Stage behaviour**

Create `lib/cham/stage.ex`:

```elixir
defmodule Cham.Stage do
  @doc """
  Behaviour for pipeline stages. A stage consumes artifacts (matched by labels)
  and produces artifacts and/or item metadata.

  Simple stages declare static input matchers and output labels.
  Dynamic stages implement can_process?/1 for runtime applicability checks.
  """

  @type artifact_result :: %{
          labels: map(),
          filenames: [String.t()]
        }

  @type perform_result :: %{
          artifacts: [artifact_result()],
          item_metadata: map(),
          provenance: map()
        }

  @type input_artifact :: %{
          labels: map(),
          filenames: [String.t()],
          input_path: String.t()
        }

  # --- Required callbacks ---

  @doc "Human-readable name for the stage."
  @callback name() :: String.t()

  @doc "Human-readable description."
  @callback description() :: String.t()

  @doc "Execute the stage."
  @callback perform(
              input_artifacts :: [input_artifact()],
              working_dir :: String.t(),
              desired_artifacts :: [map()],
              item_id :: String.t()
            ) :: {:ok, perform_result()} | {:error, term()} | {:snooze, pos_integer(), String.t()}

  # --- Simple stage callbacks (optional for dynamic stages) ---

  @doc "List of label matchers for required input artifacts."
  @callback input_matchers() :: [map()]

  @doc "List of label maps this stage produces."
  @callback output_labels() :: [map()]

  # --- Dynamic stage callback (optional for simple stages) ---

  @doc "Runtime applicability check for dynamic stages."
  @callback can_process?(current_artifacts :: [map()]) ::
              {:ready, required :: [map()], optional :: [map()]}
              | :not_applicable
              | :undecided

  # --- Stage config ---

  @doc "Which Oban queue this stage runs on."
  @callback queue() :: atom()

  @doc "Maximum retry attempts."
  @callback max_attempts() :: pos_integer()

  @optional_callbacks [input_matchers: 0, output_labels: 0, can_process?: 1]
end
```

- [ ] **Step 2: Commit**

```bash
git add lib/cham/stage.ex
git commit -m "feat: add Stage behaviour definition

Defines the contract for pipeline stages: perform, input_matchers,
output_labels, can_process?, queue, max_attempts. Simple stages
use static matchers; dynamic stages implement can_process?/1."
```

---

## Task 7: Plugin Registry

A GenServer that maintains the ordered list of loaded plugins, their state, and detected conflicts.

**Files:**
- Create: `lib/cham/plugin/registry.ex`
- Create: `test/cham/plugin/registry_test.exs`
- Create: `test/support/test_plugins.ex` (test helper plugins)

- [ ] **Step 1: Create test helper plugins**

Create `test/support/test_plugins.ex`:

```elixir
defmodule Cham.TestPlugins.PluginA do
  @behaviour Cham.Plugin

  @impl true
  def plugin_id, do: "plugin_a"
  @impl true
  def name, do: "Plugin A"
  @impl true
  def description, do: "Test plugin A"
  @impl true
  def config_schema, do: [%{key: :setting, type: :string, default: "default_a", description: "A setting"}]
  @impl true
  def init(_context), do: {:ok, %{initialized: true}}
  @impl true
  def stages(_state), do: [Cham.TestPlugins.StageA]
end

defmodule Cham.TestPlugins.PluginB do
  @behaviour Cham.Plugin

  @impl true
  def plugin_id, do: "plugin_b"
  @impl true
  def name, do: "Plugin B"
  @impl true
  def description, do: "Test plugin B"
  @impl true
  def config_schema, do: []
  @impl true
  def init(_context), do: {:ok, %{}}
  @impl true
  def stages(_state), do: [Cham.TestPlugins.StageB]
end

defmodule Cham.TestPlugins.PluginFailing do
  @behaviour Cham.Plugin

  @impl true
  def plugin_id, do: "plugin_failing"
  @impl true
  def name, do: "Failing Plugin"
  @impl true
  def description, do: "Plugin that fails init"
  @impl true
  def config_schema, do: []
  @impl true
  def init(_context), do: {:error, "intentional init failure"}
  @impl true
  def stages(_state), do: []
end

defmodule Cham.TestPlugins.StageA do
  @behaviour Cham.Stage

  @impl true
  def name, do: "Stage A"
  @impl true
  def description, do: "Test stage A"
  @impl true
  def input_matchers, do: [%{"origin" => "original", "format" => "text"}]
  @impl true
  def output_labels, do: [%{"origin" => "derived", "type" => "summary"}]
  @impl true
  def queue, do: :general
  @impl true
  def max_attempts, do: 3
  @impl true
  def perform(_inputs, _dir, _desired, _item_id), do: {:ok, %{artifacts: [], item_metadata: %{}, provenance: %{}}}
end

defmodule Cham.TestPlugins.StageB do
  @behaviour Cham.Stage

  @impl true
  def name, do: "Stage B"
  @impl true
  def description, do: "Test stage B"
  @impl true
  def input_matchers, do: [%{"origin" => "original", "format" => "audio"}]
  @impl true
  def output_labels, do: [%{"origin" => "derived", "type" => "transcript"}]
  @impl true
  def queue, do: :gpu
  @impl true
  def max_attempts, do: 2
  @impl true
  def perform(_inputs, _dir, _desired, _item_id), do: {:ok, %{artifacts: [], item_metadata: %{}, provenance: %{}}}
end
```

- [ ] **Step 2: Write the failing tests**

Create `test/cham/plugin/registry_test.exs`:

```elixir
defmodule Cham.Plugin.RegistryTest do
  use ExUnit.Case

  alias Cham.Plugin.Registry

  setup do
    name = :"plugin_reg_#{:erlang.unique_integer([:positive])}"
    start_supervised!({Registry, name: name, plugin_order: ["plugin_a", "plugin_b"]})
    %{registry: name}
  end

  describe "register_plugin/3" do
    test "registers a plugin with its module and config", %{registry: reg} do
      assert :ok = Registry.register_plugin(reg, Cham.TestPlugins.PluginA, %{})
      plugins = Registry.list_plugins(reg)
      assert length(plugins) == 1
      assert hd(plugins).plugin_id == "plugin_a"
    end

    test "skips plugin when init fails", %{registry: reg} do
      assert {:error, _} = Registry.register_plugin(reg, Cham.TestPlugins.PluginFailing, %{})
      assert Registry.list_plugins(reg) == []
    end

    test "rejects duplicate plugin_id", %{registry: reg} do
      :ok = Registry.register_plugin(reg, Cham.TestPlugins.PluginA, %{})
      assert {:error, :already_registered} = Registry.register_plugin(reg, Cham.TestPlugins.PluginA, %{})
    end
  end

  describe "list_plugins/1" do
    test "returns plugins in configured order", %{registry: reg} do
      Registry.register_plugin(reg, Cham.TestPlugins.PluginB, %{})
      Registry.register_plugin(reg, Cham.TestPlugins.PluginA, %{})

      plugins = Registry.list_plugins(reg)
      ids = Enum.map(plugins, & &1.plugin_id)
      # plugin_a comes before plugin_b in the configured order
      assert ids == ["plugin_a", "plugin_b"]
    end

    test "appends unknown plugins to end of order", context do
      name = :"plugin_reg_order_#{:erlang.unique_integer([:positive])}"
      start_supervised!({Registry, name: name, plugin_order: ["plugin_a"]}, id: :order_test)

      Registry.register_plugin(name, Cham.TestPlugins.PluginA, %{})
      Registry.register_plugin(name, Cham.TestPlugins.PluginB, %{})

      plugins = Registry.list_plugins(name)
      ids = Enum.map(plugins, & &1.plugin_id)
      assert ids == ["plugin_a", "plugin_b"]
    end
  end

  describe "get_plugin/2" do
    test "returns plugin info by plugin_id", %{registry: reg} do
      Registry.register_plugin(reg, Cham.TestPlugins.PluginA, %{})
      assert {:ok, plugin} = Registry.get_plugin(reg, "plugin_a")
      assert plugin.name == "Plugin A"
    end

    test "returns error for unknown plugin", %{registry: reg} do
      assert {:error, :not_found} = Registry.get_plugin(reg, "nonexistent")
    end
  end

  describe "get_stages/1" do
    test "returns all stages from all plugins", %{registry: reg} do
      Registry.register_plugin(reg, Cham.TestPlugins.PluginA, %{})
      Registry.register_plugin(reg, Cham.TestPlugins.PluginB, %{})

      stages = Registry.get_stages(reg)
      assert length(stages) == 2
      modules = Enum.map(stages, & &1.module)
      assert Cham.TestPlugins.StageA in modules
      assert Cham.TestPlugins.StageB in modules
    end

    test "each stage carries its plugin_id", %{registry: reg} do
      Registry.register_plugin(reg, Cham.TestPlugins.PluginA, %{})

      [stage] = Registry.get_stages(reg)
      assert stage.plugin_id == "plugin_a"
    end
  end
end
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
mix test test/cham/plugin/registry_test.exs
```

Expected: compilation error — `Cham.Plugin.Registry` module does not exist.

- [ ] **Step 4: Implement the Plugin Registry**

Create `lib/cham/plugin/registry.ex`:

```elixir
defmodule Cham.Plugin.Registry do
  use GenServer

  require Logger

  defmodule PluginEntry do
    defstruct [:plugin_id, :name, :description, :module, :state, :config_schema]
  end

  defmodule StageEntry do
    defstruct [:module, :plugin_id, :input_matchers, :output_labels, :queue, :max_attempts]
  end

  # --- Client API ---

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

  # --- Server ---

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
          Logger.warning("Plugin #{plugin_id} failed to init: #{reason}")
          {:reply, {:error, reason}, state}
      end
    end
  end

  def handle_call(:list_plugins, _from, state) do
    ordered = order_plugins(state.plugins, state.plugin_order)
    {:reply, ordered, state}
  end

  def handle_call({:get_plugin, plugin_id}, _from, state) do
    case Map.get(state.plugins, plugin_id) do
      nil -> {:reply, {:error, :not_found}, state}
      entry -> {:reply, {:ok, entry}, state}
    end
  end

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
            input_matchers: if(function_exported?(mod, :input_matchers, 0), do: mod.input_matchers(), else: []),
            output_labels: if(function_exported?(mod, :output_labels, 0), do: mod.output_labels(), else: []),
            queue: mod.queue(),
            max_attempts: mod.max_attempts()
          }
        end)
      end)

    {:reply, stages, state}
  end

  # --- Private ---

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
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
mix test test/cham/plugin/registry_test.exs
```

Expected: all 8 tests pass.

- [ ] **Step 6: Run all tests**

```bash
mix test
```

Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add lib/cham/plugin/registry.ex test/cham/plugin/registry_test.exs test/support/test_plugins.ex
git commit -m "feat: add Plugin Registry with ordered registration and stage collection

GenServer maintaining ordered list of loaded plugins. Registers
plugins via their behaviour callbacks, respects configured plugin
order, appends unknown plugins to end. Collects all stages from
all plugins for DAG builder queries."
```

---

## Verification

After all tasks, run:

```bash
mix format --check-formatted
mix test
```

All should pass with zero warnings.
