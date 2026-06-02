defmodule Cham.Plugin.Registry do
  @moduledoc """
  Discovers, validates, and catalogs plugins at startup. Scans the configured
  plugins root for `manifest.toml` directories, adds compile-time in-process
  behaviour modules, builds the artifact-type vocabulary, validates each
  plugin's typed I/O, registers per-plugin config schemas, and holds the static
  catalog (`id => manifest`). Malformed or unknown-type plugins are logged and
  skipped — never fatal to boot.
  """
  use GenServer
  require Logger
  alias Cham.Plugin.{ArtifactType, Manifest}

  # --- Public API ---

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Look up a manifest by id."
  @spec lookup(GenServer.server(), String.t()) :: {:ok, Manifest.t()} | :error
  def lookup(server \\ __MODULE__, id), do: GenServer.call(server, {:lookup, id})

  @doc "All catalogued manifests."
  @spec list(GenServer.server()) :: [Manifest.t()]
  def list(server \\ __MODULE__), do: GenServer.call(server, :list)

  @doc "The artifact-type vocabulary."
  @spec vocabulary(GenServer.server()) :: ArtifactType.vocabulary()
  def vocabulary(server \\ __MODULE__), do: GenServer.call(server, :vocabulary)

  # --- Pure discovery (unit-testable without a process) ---

  @doc """
  Build `{catalog, vocabulary}` from options:
  `:plugins_root`, `:in_process_modules`, `:seeded_types`, `:disabled`,
  `:config_register` (a `(namespace, schema -> any)` function).
  """
  def discover(opts) do
    seeded = Keyword.get(opts, :seeded_types, ArtifactType.default_seeded())
    disabled = Keyword.get(opts, :disabled, [])
    config_register = Keyword.get(opts, :config_register, &Cham.Config.Manager.register/2)

    manifests =
      (scan_subprocess(Keyword.get(opts, :plugins_root, "plugins")) ++
         load_in_process(Keyword.get(opts, :in_process_modules, [])))
      |> Enum.reject(&(&1.id in disabled))

    vocabulary = ArtifactType.build(seeded, Enum.map(manifests, & &1.declares_types))

    kept = Enum.filter(manifests, &valid_types?(&1, vocabulary))
    Enum.each(kept, &register_config(&1, config_register))

    catalog = Map.new(kept, &{&1.id, &1})
    {catalog, vocabulary}
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    {catalog, vocabulary} = discover(opts)
    {:ok, %{catalog: catalog, vocabulary: vocabulary}}
  end

  @impl true
  def handle_call({:lookup, id}, _from, state) do
    {:reply, Map.fetch(state.catalog, id), state}
  end

  def handle_call(:list, _from, state) do
    {:reply, Map.values(state.catalog), state}
  end

  def handle_call(:vocabulary, _from, state) do
    {:reply, state.vocabulary, state}
  end

  # --- Internals ---

  defp scan_subprocess(root) do
    case File.ls(root) do
      {:ok, entries} ->
        entries
        |> Enum.map(&Path.join([root, &1, "manifest.toml"]))
        |> Enum.filter(&File.regular?/1)
        |> Enum.flat_map(&parse_manifest/1)

      {:error, _} ->
        []
    end
  end

  defp parse_manifest(path) do
    case Manifest.parse(path) do
      {:ok, m} ->
        [m]

      {:error, reason} ->
        Logger.warning("skipping plugin manifest #{path}: #{reason}")
        []
    end
  end

  defp load_in_process(modules) do
    Enum.flat_map(modules, fn module ->
      manifest = %{module.manifest() | class: :in_process, source: {:module, module}}

      case Manifest.validate(manifest) do
        {:ok, m} ->
          [m]

        {:error, reason} ->
          Logger.warning("skipping in-process plugin #{inspect(module)}: #{reason}")
          []
      end
    end)
  end

  defp valid_types?(manifest, vocabulary) do
    types = Enum.map(manifest.inputs ++ manifest.outputs, & &1.type)

    case ArtifactType.validate_types(types, vocabulary) do
      :ok ->
        true

      {:error, reason} ->
        Logger.warning("skipping plugin #{manifest.id}: #{reason}")
        false
    end
  end

  defp register_config(%{config_schema: []}, _fun), do: :ok

  defp register_config(%{id: id, config_schema: schema}, fun) do
    fun.("plugins.#{id}", schema)
    :ok
  end
end
