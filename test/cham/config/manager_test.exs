defmodule Cham.Config.ManagerTest do
  use ExUnit.Case

  alias Cham.Config.Manager

  @worker_schema [
    %{key: :queue_general, type: :integer, default: 5, description: "General queue concurrency"},
    %{key: :queue_network, type: :integer, default: 3, description: "Network queue concurrency"},
    %{
      key: :mode,
      type: :string,
      default: "balanced",
      description: "Mode",
      options: ["balanced", "fast"]
    }
  ]

  setup do
    name = :"config_mgr_#{:erlang.unique_integer([:positive])}"
    path = Path.join(System.tmp_dir!(), "#{name}.toml")
    %{name: name, toml_path: path}
  end

  defp start_manager(context, toml_content \\ "") do
    File.write!(context.toml_path, toml_content)

    start_supervised!(
      {Manager, name: context.name, toml_path: context.toml_path, event_bus: nil}
    )

    context
  end

  defp start_manager_with_events(context, toml_content \\ "") do
    File.write!(context.toml_path, toml_content)

    start_supervised!(
      {Manager, name: context.name, toml_path: context.toml_path, event_bus: Cham.PubSub}
    )

    context
  end

  describe "register/3 and read_all/2" do
    test "registers a schema and returns defaults when no values in file", context do
      start_manager(context)
      :ok = Manager.register(context.name, "worker", @worker_schema)
      assert {:ok, config} = Manager.read_all(context.name, "worker")
      assert config == %{queue_general: 5, queue_network: 3, mode: "balanced"}
    end

    test "returns values from TOML file merged with defaults", context do
      start_manager(context, """
      [worker]
      queue_general = 10
      """)

      :ok = Manager.register(context.name, "worker", @worker_schema)
      assert {:ok, config} = Manager.read_all(context.name, "worker")
      assert config.queue_general == 10
      assert config.queue_network == 3
    end

    test "returns error for unregistered namespace", context do
      start_manager(context)
      assert {:error, :unknown_namespace} = Manager.read_all(context.name, "nonexistent")
    end

    test "rejects duplicate namespace registration", context do
      start_manager(context)
      :ok = Manager.register(context.name, "worker", @worker_schema)

      assert {:error, :already_registered} =
               Manager.register(context.name, "worker", @worker_schema)
    end
  end

  describe "write_all/3" do
    test "writes values and persists to TOML file", context do
      start_manager(context)
      :ok = Manager.register(context.name, "worker", @worker_schema)
      :ok = Manager.write_all(context.name, "worker", %{queue_general: 10})

      assert {:ok, config} = Manager.read_all(context.name, "worker")
      assert config.queue_general == 10

      file_content = File.read!(context.toml_path)
      assert file_content =~ "queue_general = 10"
    end

    test "validates values against schema on write", context do
      start_manager(context)
      :ok = Manager.register(context.name, "worker", @worker_schema)

      assert {:error, _} =
               Manager.write_all(context.name, "worker", %{queue_general: "not_int"})
    end

    test "validates enum options on write", context do
      start_manager(context)
      :ok = Manager.register(context.name, "worker", @worker_schema)

      assert {:error, _} = Manager.write_all(context.name, "worker", %{mode: "turbo"})
    end

    test "returns error for unregistered namespace", context do
      start_manager(context)
      assert {:error, :unknown_namespace} = Manager.write_all(context.name, "nope", %{key: 1})
    end

    test "preserves other namespaces when writing", context do
      start_manager(context)
      archive_schema = [%{key: :path, type: :string, default: "archive", description: "Path"}]

      :ok = Manager.register(context.name, "worker", @worker_schema)
      :ok = Manager.register(context.name, "archive", archive_schema)
      :ok = Manager.write_all(context.name, "archive", %{path: "/data/archive"})
      :ok = Manager.write_all(context.name, "worker", %{queue_general: 10})

      assert {:ok, archive_config} = Manager.read_all(context.name, "archive")
      assert archive_config.path == "/data/archive"
    end

    test "persisted values survive restart", context do
      start_manager(context)
      :ok = Manager.register(context.name, "worker", @worker_schema)
      :ok = Manager.write_all(context.name, "worker", %{queue_general: 10})

      stop_supervised!(Manager)

      name2 = :"config_reload_#{:erlang.unique_integer([:positive])}"

      start_supervised!(
        {Manager, name: name2, toml_path: context.toml_path, event_bus: nil},
        id: :restarted
      )

      :ok = Manager.register(name2, "worker", @worker_schema)
      assert {:ok, config} = Manager.read_all(name2, "worker")
      assert config.queue_general == 10
    end
  end

  describe "list_schemas/1" do
    test "returns all registered namespaces and their schemas", context do
      start_manager(context)
      archive_schema = [%{key: :path, type: :string, default: "archive", description: "Path"}]

      :ok = Manager.register(context.name, "worker", @worker_schema)
      :ok = Manager.register(context.name, "archive", archive_schema)

      schemas = Manager.list_schemas(context.name)

      assert length(schemas) == 2
      assert Enum.any?(schemas, fn {ns, _} -> ns == "worker" end)
      assert Enum.any?(schemas, fn {ns, _} -> ns == "archive" end)
    end
  end

  describe "event bus integration" do
    test "publishes config change event on write_all", context do
      start_manager_with_events(context)
      :ok = Manager.register(context.name, "worker", @worker_schema)

      Cham.EventBus.subscribe("config:worker")

      :ok = Manager.write_all(context.name, "worker", %{queue_general: 10})

      assert_receive %Cham.Config.Manager.ConfigChanged{
        namespace: "worker",
        values: %{queue_general: 10}
      }
    end

    test "publishes to coarse config topic too", context do
      start_manager_with_events(context)
      :ok = Manager.register(context.name, "worker", @worker_schema)

      Cham.EventBus.subscribe("config")

      :ok = Manager.write_all(context.name, "worker", %{queue_general: 10})

      assert_receive %Cham.Config.Manager.ConfigChanged{namespace: "worker"}
    end

    test "does not publish event when event_bus is nil", context do
      start_manager(context)
      :ok = Manager.register(context.name, "worker", @worker_schema)

      Cham.EventBus.subscribe("config:worker")

      :ok = Manager.write_all(context.name, "worker", %{queue_general: 10})

      refute_receive %Cham.Config.Manager.ConfigChanged{}
    end
  end
end
