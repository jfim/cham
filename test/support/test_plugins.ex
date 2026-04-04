defmodule Cham.TestPlugins.PluginA do
  @behaviour Cham.Plugin

  @impl true
  def plugin_id, do: "plugin_a"
  @impl true
  def name, do: "Plugin A"
  @impl true
  def description, do: "Test plugin A"
  @impl true
  def config_schema,
    do: [%{key: :setting, type: :string, default: "default_a", description: "A setting"}]

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
  def perform(_inputs, _dir, _desired, _item_id),
    do: {:ok, %{artifacts: [], item_metadata: %{}, provenance: %{}}}
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
  def perform(_inputs, _dir, _desired, _item_id),
    do: {:ok, %{artifacts: [], item_metadata: %{}, provenance: %{}}}
end

defmodule Cham.TestPlugins.EchoStage do
  @behaviour Cham.Stage

  @impl true
  def name, do: "Echo Stage"
  @impl true
  def description, do: "Test stage that echoes input to output"
  @impl true
  def input_matchers, do: [%{"domain" => "example.com"}]
  @impl true
  def output_labels, do: [%{"origin" => "original", "format" => "text"}]
  @impl true
  def queue, do: :general
  @impl true
  def max_attempts, do: 3

  @impl true
  def perform(_inputs, working_dir, _desired, _item_id) do
    File.write!(Path.join(working_dir, "output.txt"), "echo output")

    {:ok,
     %{
       artifacts: [
         %{labels: %{"origin" => "original", "format" => "text"}, filenames: ["output.txt"]}
       ],
       item_metadata: %{"title" => "Test Item", "content_type" => "article"},
       provenance: %{"plugin_version" => "0.1.0"}
     }}
  end
end
