defmodule Cham.ScriptRunnerTest do
  use ExUnit.Case, async: true

  alias Cham.ScriptRunner
  alias Cham.ScriptRunner.Events.{ScriptOutput, ScriptExited, ScriptTimeout}

  describe "run_sync/3" do
    test "runs a command and captures stdout" do
      assert {:ok, stdout, _stderr, 0} =
               ScriptRunner.run_sync("echo", ["hello world"], timeout: 5_000)

      assert String.trim(stdout) == "hello world"
    end

    test "captures stderr" do
      assert {:ok, stdout, _stderr, 0} =
               ScriptRunner.run_sync("sh", ["-c", "echo errout >&2"], timeout: 5_000)

      # stderr_to_stdout merges them
      assert stdout =~ "errout"
    end

    test "returns non-zero exit code" do
      assert {:ok, _stdout, _stderr, 1} =
               ScriptRunner.run_sync("sh", ["-c", "exit 1"], timeout: 5_000)
    end

    test "returns timeout error when command exceeds timeout" do
      assert {:error, :timeout, _stdout, _stderr} =
               ScriptRunner.run_sync("sleep", ["10"], timeout: 500)
    end

    test "writes output to log file when log_to is specified" do
      log_path =
        Path.join(
          System.tmp_dir!(),
          "cham_sr_test_#{:erlang.unique_integer([:positive])}.log"
        )

      on_exit(fn -> File.rm(log_path) end)

      {:ok, _stdout, _stderr, 0} =
        ScriptRunner.run_sync("echo", ["logged_output"], timeout: 5_000, log_to: log_path)

      assert File.read!(log_path) =~ "logged_output"
    end
  end

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
end
