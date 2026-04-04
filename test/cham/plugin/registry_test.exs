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

      assert {:error, :already_registered} =
               Registry.register_plugin(reg, Cham.TestPlugins.PluginA, %{})
    end
  end

  describe "list_plugins/1" do
    test "returns plugins in configured order", %{registry: reg} do
      Registry.register_plugin(reg, Cham.TestPlugins.PluginB, %{})
      Registry.register_plugin(reg, Cham.TestPlugins.PluginA, %{})

      plugins = Registry.list_plugins(reg)
      ids = Enum.map(plugins, & &1.plugin_id)
      assert ids == ["plugin_a", "plugin_b"]
    end

    test "appends unknown plugins to end of order" do
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
