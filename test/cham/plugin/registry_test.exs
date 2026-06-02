defmodule Cham.Plugin.RegistryTest do
  use ExUnit.Case, async: true
  alias Cham.Plugin.{ArtifactType, Registry}
  alias Cham.PluginFixtures.FakeStage

  @root "test/support/plugin_fixtures"

  defp opts(extra) do
    parent = self()

    Keyword.merge(
      [
        plugins_root: @root,
        in_process_modules: [],
        seeded_types: ArtifactType.default_seeded(),
        disabled: [],
        config_register: fn ns, schema ->
          send(parent, {:config_registered, ns, schema})
          :ok
        end
      ],
      extra
    )
  end

  describe "discover/1" do
    test "discovers valid subprocess manifests and skips malformed/unknown-type ones" do
      {catalog, _vocab} = Registry.discover(opts([]))
      ids = Map.keys(catalog)

      assert "echo_stage" in ids
      assert "extract_article" in ids
      refute "malformed_stage" in ids
      refute "bad_types_stage" in ids
    end

    test "includes compile-time in-process modules and stamps their source" do
      {catalog, _vocab} = Registry.discover(opts(in_process_modules: [FakeStage]))
      assert %{class: :in_process, source: {:module, FakeStage}} = catalog["fake_stage"]
    end

    test "drops disabled plugin ids" do
      {catalog, _vocab} = Registry.discover(opts(disabled: ["echo_stage"]))
      refute Map.has_key?(catalog, "echo_stage")
      assert Map.has_key?(catalog, "extract_article")
    end

    test "builds a vocabulary of seeded plus declared types" do
      {_catalog, vocab} = Registry.discover(opts([]))
      assert ArtifactType.known?(vocab, "html_capture")
      assert ArtifactType.known?(vocab, "article_markdown")
    end

    test "registers config schemas for plugins that declare them" do
      Registry.discover(opts([]))
      assert_receive {:config_registered, "plugins.extract_article", [%{key: :min_words}]}
    end

    test "skips an in-process module whose manifest/0 raises, without crashing discovery" do
      {catalog, _vocab} =
        Registry.discover(opts(in_process_modules: [Cham.PluginFixtures.RaisingStage, FakeStage]))

      # discovery did not crash; the raising module is skipped, the good one kept
      refute Enum.any?(
               Map.values(catalog),
               &match?(%{source: {:module, Cham.PluginFixtures.RaisingStage}}, &1)
             )

      assert Map.has_key?(catalog, "fake_stage")
    end
  end

  describe "GenServer API" do
    test "lookup and list reflect the discovered catalog" do
      start_supervised!({Registry, opts(name: :test_registry, in_process_modules: [FakeStage])})

      assert {:ok, %{id: "echo_stage"}} = Registry.lookup(:test_registry, "echo_stage")

      assert {:ok, %{id: "fake_stage", class: :in_process}} =
               Registry.lookup(:test_registry, "fake_stage")

      assert :error = Registry.lookup(:test_registry, "nope")
      assert "echo_stage" in Enum.map(Registry.list(:test_registry), & &1.id)
    end
  end
end
