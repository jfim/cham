defmodule Cham.Plugin.RuntimeTest do
  use ExUnit.Case, async: true
  alias Cham.Plugin.{ArtifactType, Registry, Runtime}
  alias Cham.Plugin.WireProtocol.{CanProcessRequest, PerformRequest, StageResult}
  alias Cham.PluginFixtures.FakeStage

  @root "test/support/plugin_fixtures"

  setup do
    start_supervised!(
      {Registry,
       name: :runtime_registry,
       plugins_root: @root,
       in_process_modules: [FakeStage],
       seeded_types: ArtifactType.default_seeded(),
       disabled: [],
       config_register: fn _ns, _schema -> :ok end}
    )

    :ok
  end

  @tag :tmp_dir
  test "dispatches an in-process stage perform", %{tmp_dir: wd} do
    req = %PerformRequest{item_id: "i", inputs: []}

    assert %StageResult{outcome: :produced, item_metadata: %{"title" => "Faked"}} =
             Runtime.run("fake_stage", req, wd, registry: :runtime_registry)
  end

  @tag :tmp_dir
  test "dispatches a subprocess stage perform", %{tmp_dir: wd} do
    req = %PerformRequest{item_id: "i", inputs: []}

    assert %StageResult{outcome: :produced, item_metadata: %{"title" => "Echo"}} =
             Runtime.run("echo_stage", req, wd, registry: :runtime_registry, timeout: 10_000)
  end

  @tag :tmp_dir
  test "dispatches a can_process probe (both classes)", %{tmp_dir: wd} do
    inproc = %CanProcessRequest{item_id: "i", inputs: [%{type: "html_capture"}]}
    assert {:ok, true} = Runtime.run("fake_stage", inproc, wd, registry: :runtime_registry)

    sub = %CanProcessRequest{item_id: "i", inputs: []}

    assert {:ok, true} =
             Runtime.run("echo_stage", sub, wd, registry: :runtime_registry, timeout: 10_000)
  end

  @tag :tmp_dir
  test "returns {:error, :unknown_plugin} for an unregistered id", %{tmp_dir: wd} do
    req = %PerformRequest{item_id: "i", inputs: []}
    assert {:error, :unknown_plugin} = Runtime.run("ghost", req, wd, registry: :runtime_registry)
  end
end
