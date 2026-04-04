defmodule Cham.Plugins.RegistrationTest do
  use Cham.DataCase

  alias Cham.Plugin.Registry

  @core_plugin_modules [
    Cham.Plugins.GenericDownloadUrl,
    Cham.Plugins.ContentTypeRouter,
    Cham.Plugins.ExtractArticle,
    Cham.Plugins.TranscribeWhisper,
    Cham.Plugins.SummarizeOllama,
    Cham.Plugins.AutoTag,
    Cham.Plugins.CleanTitle
  ]

  @core_plugin_ids [
    "generic_download_url",
    "content_type_router",
    "extract_article",
    "transcribe_whisper",
    "summarize_ollama",
    "auto_tag",
    "clean_title"
  ]

  describe "core plugin validation" do
    test "all core plugins have valid plugin_id" do
      plugin_ids = Enum.map(@core_plugin_modules, & &1.plugin_id())
      assert Enum.sort(plugin_ids) == Enum.sort(@core_plugin_ids)
    end

    test "all core plugins init successfully" do
      for mod <- @core_plugin_modules do
        assert {:ok, _state} = mod.init(%{config: %{}}),
               "#{inspect(mod)} failed to init"
      end
    end

    test "all core plugins provide at least one stage" do
      for mod <- @core_plugin_modules do
        stages = mod.stages(%{})
        assert length(stages) >= 1, "#{inspect(mod)} has no stages"
      end
    end

    test "can register all core plugins in a fresh registry" do
      name = :"test_registry_#{System.unique_integer([:positive])}"
      {:ok, registry} = Registry.start_link(name: name, plugin_order: @core_plugin_ids)

      for mod <- @core_plugin_modules do
        assert :ok = Registry.register_plugin(registry, mod, %{})
      end

      plugins = Registry.list_plugins(registry)
      assert length(plugins) == 7

      stages = Registry.get_stages(registry)
      assert length(stages) >= 7
    end
  end
end
