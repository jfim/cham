defmodule Cham.Plugin.Transport.SubprocessTest do
  use ExUnit.Case, async: true
  alias Cham.Plugin.Transport.Subprocess
  alias Cham.Plugin.Manifest
  alias Cham.Plugin.WireProtocol.{PerformRequest, CanProcessRequest, StageResult}
  alias Cham.Plugin.Events.PluginEvent

  @fixtures "test/support/plugin_fixtures"

  defp manifest(dir, entrypoints) do
    %Manifest{
      id: Path.basename(dir),
      kind: :stage,
      phase: :extract,
      version: 1,
      entrypoints: entrypoints,
      class: :subprocess,
      source: {:dir, Path.expand(Path.join(@fixtures, dir))}
    }
  end

  @tag :tmp_dir
  test "perform reads request.json, forwards JSONL events, parses output.json", %{tmp_dir: wd} do
    m = manifest("echo_stage", %{perform: "sh perform.sh", can_process: "sh check.sh"})
    Cham.EventBus.subscribe("plugin:echo_stage")
    req = %PerformRequest{item_id: "item-1", inputs: []}

    assert %StageResult{outcome: :produced, item_metadata: %{"title" => "Echo"}} =
             Subprocess.invoke(m, req, wd, timeout: 10_000)

    assert File.read!(Path.join(wd, "request.json")) =~ ~s("item_id")
    assert_receive %PluginEvent{type: :status, data: %{"message" => "starting"}}
    assert_receive %PluginEvent{type: :progress, data: %{"value" => 50}}
  end

  @tag :tmp_dir
  test "stderr is captured to the log file", %{tmp_dir: wd} do
    m = manifest("echo_stage", %{perform: "sh perform.sh", can_process: nil})
    log = Path.join(wd, "stage.log")
    req = %PerformRequest{item_id: "i", inputs: []}

    Subprocess.invoke(m, req, wd, timeout: 10_000, log_to: log)
    assert File.read!(log) =~ "a raw stderr log line"
  end

  @tag :tmp_dir
  test "a stale output.json from a previous run is deleted before invoking", %{tmp_dir: wd} do
    File.write!(Path.join(wd, "output.json"), ~s({"outcome":"not_applicable"}))
    m = manifest("echo_stage", %{perform: "sh perform.sh", can_process: nil})
    req = %PerformRequest{item_id: "i", inputs: []}

    assert %StageResult{outcome: :produced} = Subprocess.invoke(m, req, wd, timeout: 10_000)
  end

  @tag :tmp_dir
  test "missing output.json (crash) maps to failed(:error)", %{tmp_dir: wd} do
    m = manifest("crash_stage", %{perform: "sh perform.sh", can_process: nil})
    req = %PerformRequest{item_id: "i", inputs: []}

    assert %StageResult{outcome: :failed, category: :error} =
             Subprocess.invoke(m, req, wd, timeout: 10_000)
  end

  @tag :tmp_dir
  test "garbage output.json maps to failed(:error)", %{tmp_dir: wd} do
    File.write!(Path.join(wd, "perform_marker"), "")

    m =
      manifest("echo_stage", %{
        perform: "sh -c 'printf nonsense > \"$1/output.json\"' --",
        can_process: nil
      })

    req = %PerformRequest{item_id: "i", inputs: []}

    assert %StageResult{outcome: :failed, category: :error} =
             Subprocess.invoke(m, req, wd, timeout: 10_000)
  end

  @tag :tmp_dir
  test "timeout kills the process and maps to failed(:error)", %{tmp_dir: wd} do
    m = manifest("slow_stage", %{perform: "sh perform.sh", can_process: nil})
    req = %PerformRequest{item_id: "i", inputs: []}

    assert %StageResult{outcome: :failed, category: :error} =
             Subprocess.invoke(m, req, wd, timeout: 300)
  end

  @tag :tmp_dir
  test "can_process probe returns {:ok, boolean}", %{tmp_dir: wd} do
    m = manifest("echo_stage", %{perform: "sh perform.sh", can_process: "sh check.sh"})
    req = %CanProcessRequest{item_id: "i", inputs: []}

    assert {:ok, true} = Subprocess.invoke(m, req, wd, timeout: 10_000)
  end
end
