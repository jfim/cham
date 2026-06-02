defmodule Cham.Plugin.SubscriptionContractTest do
  use ExUnit.Case, async: true
  alias Cham.Plugin.{Runtime, Registry, ArtifactType}
  alias Cham.Plugin.WireProtocol.{SubscriptionRequest, SubscriptionResult}
  alias Cham.PluginFixtures.FakeSubscription

  @root "test/support/plugin_fixtures"

  setup do
    start_supervised!(
      {Registry,
       name: :sub_registry,
       plugins_root: @root,
       in_process_modules: [FakeSubscription],
       seeded_types: ArtifactType.default_seeded(),
       disabled: [],
       config_register: fn _ns, _schema -> :ok end}
    )

    :ok
  end

  @tag :tmp_dir
  test "in-process subscription round-trips the opaque checkpoint", %{tmp_dir: wd} do
    first = %SubscriptionRequest{subscription_id: "s", checkpoint: nil}

    assert %SubscriptionResult{items: [%{"url" => "https://x/1"}], checkpoint: "v1"} =
             Runtime.run("fake_subscription", first, wd, registry: :sub_registry)

    # Feed the issued checkpoint back: the plugin recognizes it and reports nothing new.
    second = %SubscriptionRequest{subscription_id: "s", checkpoint: "v1"}

    assert %SubscriptionResult{items: [], checkpoint: "v1"} =
             Runtime.run("fake_subscription", second, wd, registry: :sub_registry)
  end

  @tag :tmp_dir
  test "subprocess subscription returns items + checkpoint and receives the checkpoint", %{
    tmp_dir: wd
  } do
    req = %SubscriptionRequest{subscription_id: "s", checkpoint: "prev-cursor", config: %{}}

    assert %SubscriptionResult{items: [%{"url" => "https://feed/1"}], checkpoint: "etag-xyz"} =
             Runtime.run("sub_feed", req, wd, registry: :sub_registry, timeout: 10_000)

    # The checkpoint we sent was serialized into request.json for the plugin to read.
    assert File.read!(Path.join(wd, "request.json")) =~ "prev-cursor"
  end
end
