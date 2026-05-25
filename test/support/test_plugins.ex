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

defmodule Cham.TestPlugins.OldFallbackPlugin do
  @behaviour Cham.Plugin

  @impl true
  def plugin_id, do: "old_fallback"
  @impl true
  def name, do: "Old Fallback"
  @impl true
  def description, do: "Test fallback-style downloader (formerly configured fallback)"
  @impl true
  def config_schema, do: []
  @impl true
  def init(_context), do: {:ok, %{}}
  @impl true
  def stages(_state), do: [Cham.TestPlugins.OldFallbackStage]
end

defmodule Cham.TestPlugins.OldFallbackStage do
  @behaviour Cham.Stage

  @impl true
  def name, do: "Old Fallback Stage"
  @impl true
  def description, do: "Fallback-style stage with not_applicable can_process?"
  @impl true
  def input_matchers, do: [%{}]
  @impl true
  def output_labels, do: [%{"origin" => "original", "type" => "initial_download"}]
  @impl true
  def queue, do: :network
  @impl true
  def max_attempts, do: 3
  @impl true
  def can_process?(_artifact_labels), do: :not_applicable
  @impl true
  def perform(_inputs, _dir, _desired, _item_id),
    do: {:ok, %{artifacts: [], item_metadata: %{}, provenance: %{}}}
end

defmodule Cham.TestPlugins.NewFallbackPlugin do
  @behaviour Cham.Plugin

  @impl true
  def plugin_id, do: "new_fallback"
  @impl true
  def name, do: "New Fallback"
  @impl true
  def description, do: "Test fallback-style downloader (newly configured fallback)"
  @impl true
  def config_schema, do: []
  @impl true
  def init(_context), do: {:ok, %{}}
  @impl true
  def stages(_state), do: [Cham.TestPlugins.NewFallbackStage]
end

defmodule Cham.TestPlugins.NewFallbackStage do
  @behaviour Cham.Stage

  @impl true
  def name, do: "New Fallback Stage"
  @impl true
  def description, do: "Fallback-style stage with not_applicable can_process?"
  @impl true
  def input_matchers, do: [%{}]
  @impl true
  def output_labels, do: [%{"origin" => "original", "type" => "initial_download"}]
  @impl true
  def queue, do: :network
  @impl true
  def max_attempts, do: 3
  @impl true
  def can_process?(_artifact_labels), do: :not_applicable
  @impl true
  def perform(_inputs, _dir, _desired, _item_id),
    do: {:ok, %{artifacts: [], item_metadata: %{}, provenance: %{}}}
end

defmodule Cham.TestPlugins.SpecializedBootstrapPlugin do
  @behaviour Cham.Plugin

  @impl true
  def plugin_id, do: "specialized_bootstrap"
  @impl true
  def name, do: "Specialized Bootstrap"
  @impl true
  def description, do: "Specialized bootstrap stage that becomes :not_applicable after running"
  @impl true
  def config_schema, do: []
  @impl true
  def init(_context), do: {:ok, %{}}
  @impl true
  def stages(_state), do: [Cham.TestPlugins.SpecializedBootstrapStage]
end

defmodule Cham.TestPlugins.SpecializedBootstrapStage do
  @behaviour Cham.Stage

  @impl true
  def name, do: "Specialized Bootstrap Stage"
  @impl true
  def description,
    do:
      "Specialized to URLs containing 'special'; reports :not_applicable once its derived marker exists"

  @impl true
  def input_matchers, do: [%{}]
  @impl true
  def output_labels do
    [
      %{"origin" => "original", "type" => "initial_download", "format" => "special"},
      %{"origin" => "derived", "type" => "specialized_marker"}
    ]
  end

  @impl true
  def queue, do: :network
  @impl true
  def max_attempts, do: 3

  @impl true
  def can_process?(current_artifacts) do
    already_done? =
      Enum.any?(current_artifacts, fn l ->
        l["origin"] == "derived" and l["type"] == "specialized_marker"
      end)

    has_special_url? =
      Enum.any?(current_artifacts, fn l ->
        url = l["url"]
        is_binary(url) and String.contains?(url, "special")
      end)

    cond do
      already_done? -> :not_applicable
      has_special_url? -> {:ready, input_matchers(), []}
      true -> :not_applicable
    end
  end

  @impl true
  def perform(_inputs, _dir, _desired, _item_id),
    do: {:ok, %{artifacts: [], item_metadata: %{}, provenance: %{}}}
end

defmodule Cham.TestPlugins.RaisingStage do
  @behaviour Cham.Stage

  @impl true
  def name, do: "Raising Stage"
  @impl true
  def description, do: "Test stage that raises an exception"
  @impl true
  def input_matchers, do: [%{"domain" => "example.com"}]
  @impl true
  def output_labels, do: [%{"origin" => "derived", "type" => "none"}]
  @impl true
  def queue, do: :general
  @impl true
  def max_attempts, do: 1

  @impl true
  def perform(_inputs, _dir, _desired, _item_id) do
    raise "kaboom"
  end
end

defmodule Cham.TestPlugins.TransientRaisingStage do
  @behaviour Cham.Stage

  @impl true
  def name, do: "Transient Raising Stage"
  @impl true
  def description, do: "Test stage that raises, with max_attempts > 1"
  @impl true
  def input_matchers, do: [%{"domain" => "example.com"}]
  @impl true
  def output_labels, do: [%{"origin" => "derived", "type" => "none"}]
  @impl true
  def queue, do: :general
  @impl true
  def max_attempts, do: 3

  @impl true
  def perform(_inputs, _dir, _desired, _item_id) do
    raise "transient kaboom"
  end
end

defmodule Cham.TestPlugins.FailingStage do
  @behaviour Cham.Stage

  @impl true
  def name, do: "Failing Stage"
  @impl true
  def description, do: "Test stage that returns {:error, _} with retries"
  @impl true
  def input_matchers, do: [%{"domain" => "example.com"}]
  @impl true
  def output_labels, do: [%{"origin" => "derived", "type" => "none"}]
  @impl true
  def queue, do: :general
  @impl true
  def max_attempts, do: 3

  @impl true
  def perform(_inputs, _dir, _desired, _item_id) do
    {:error, :nope}
  end
end

defmodule Cham.TestPlugins.PluginEcho do
  @behaviour Cham.Plugin

  @impl true
  def plugin_id, do: "plugin_echo"
  @impl true
  def name, do: "Echo Plugin"
  @impl true
  def description, do: "Test plugin with original-producing stage"
  @impl true
  def config_schema, do: []
  @impl true
  def init(_context), do: {:ok, %{}}
  @impl true
  def stages(_state), do: [Cham.TestPlugins.EchoStage]
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
