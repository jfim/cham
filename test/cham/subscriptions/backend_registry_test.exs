defmodule Cham.Subscriptions.BackendRegistryTest do
  use ExUnit.Case, async: false

  alias Cham.Subscriptions.BackendRegistry

  defmodule FakeBackend do
    @behaviour Cham.Subscriptions.Backend
    def id, do: :fake
    def name, do: "Fake"
    def stream_pages(_url), do: []
  end

  setup do
    {:ok, _pid} = start_supervised({BackendRegistry, name: :test_registry})
    :ok
  end

  test "register/lookup roundtrip" do
    assert :ok = BackendRegistry.register(:test_registry, FakeBackend)
    assert {:ok, FakeBackend} = BackendRegistry.lookup(:test_registry, :fake)
  end

  test "lookup unknown returns :error" do
    assert :error = BackendRegistry.lookup(:test_registry, :missing)
  end

  test "list returns all registered" do
    BackendRegistry.register(:test_registry, FakeBackend)
    assert [FakeBackend] = BackendRegistry.list(:test_registry)
  end
end
