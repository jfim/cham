defmodule Cham.Plugin.Manifest do
  @moduledoc """
  The parsed, static, declarative self-description of a plugin. Source of truth
  for everything except the live `can_process` probe. Parsed from `manifest.toml`
  (subprocess plugins) or returned by an in-process behaviour's `manifest/0`.
  """

  @kinds [:stage, :subscription, :subscriber, :integration]
  @phases [:bootstrap, :extract, :process]

  @type io_decl :: %{type: String.t(), labels: map()}
  @type t :: %__MODULE__{
          id: String.t(),
          kind: atom(),
          phase: atom() | nil,
          version: pos_integer(),
          queue: String.t(),
          max_attempts: pos_integer(),
          inputs: [io_decl()],
          outputs: [io_decl()],
          declares_types: [String.t()],
          entrypoints: %{perform: String.t() | nil, can_process: String.t() | nil},
          config_schema: [map()],
          class: :subprocess | :in_process,
          source: {:dir, String.t()} | {:module, module()}
        }

  @enforce_keys [:id, :kind, :class, :source]
  defstruct id: nil,
            kind: nil,
            phase: nil,
            version: 1,
            queue: "general",
            max_attempts: 3,
            inputs: [],
            outputs: [],
            declares_types: [],
            entrypoints: %{perform: nil, can_process: nil},
            config_schema: [],
            class: nil,
            source: nil

  @doc "Known plugin kinds."
  def kinds, do: @kinds

  @doc "Parse and validate a `manifest.toml` file. `source` is `{:dir, dir}`."
  @spec parse(String.t()) :: {:ok, t()} | {:error, String.t()}
  def parse(path) do
    case File.read(path) do
      {:ok, content} -> parse_string(content, {:dir, Path.dirname(path)})
      {:error, reason} -> {:error, "cannot read #{path}: #{inspect(reason)}"}
    end
  end

  @doc "Parse and validate a TOML string for a subprocess plugin."
  @spec parse_string(String.t(), {:dir, String.t()}) :: {:ok, t()} | {:error, String.t()}
  def parse_string(content, {:dir, dir}) do
    with {:ok, raw} <- decode(content),
         {:ok, kind} <- fetch_kind(raw),
         {:ok, phase} <- fetch_phase(raw, kind) do
      manifest = %__MODULE__{
        id: Map.get(raw, "id"),
        kind: kind,
        phase: phase,
        version: Map.get(raw, "version", 1),
        queue: Map.get(raw, "queue", "general"),
        max_attempts: Map.get(raw, "max_attempts", 3),
        inputs: parse_io(Map.get(raw, "inputs", [])),
        outputs: parse_io(Map.get(raw, "outputs", [])),
        declares_types: Map.get(raw, "declares_types", []),
        entrypoints: parse_entrypoints(Map.get(raw, "entrypoints", %{})),
        config_schema: parse_config_schema(Map.get(raw, "config_schema", [])),
        class: :subprocess,
        source: {:dir, dir}
      }

      validate(manifest)
    end
  end

  @doc "Validate an already-built manifest (used for in-process `manifest/0` too)."
  @spec validate(t()) :: {:ok, t()} | {:error, String.t()}
  def validate(%__MODULE__{} = m) do
    cond do
      m.id in [nil, ""] ->
        {:error, "missing id"}

      m.kind not in @kinds ->
        {:error, "unknown kind: #{inspect(m.kind)}"}

      m.kind == :stage and m.phase not in @phases ->
        {:error, "invalid phase: #{inspect(m.phase)}"}

      m.kind in [:stage, :subscription] and is_nil(m.entrypoints.perform) and
          m.class == :subprocess ->
        {:error, "missing required entrypoint: perform"}

      true ->
        {:ok, m}
    end
  end

  defp decode(content) do
    case Toml.decode(content) do
      {:ok, map} -> {:ok, map}
      {:error, reason} -> {:error, "malformed TOML: #{inspect(reason)}"}
    end
  end

  defp fetch_kind(raw) do
    result =
      case Map.get(raw, "kind") do
        k when is_binary(k) ->
          try do
            {:ok, String.to_existing_atom(k)}
          rescue
            ArgumentError -> {:error, "unknown kind: #{inspect(k)}"}
          end

        _ ->
          {:error, "missing kind"}
      end

    case result do
      {:ok, atom} when atom in @kinds -> {:ok, atom}
      {:ok, atom} -> {:error, "unknown kind: #{inspect(atom)}"}
      err -> err
    end
  end

  defp fetch_phase(_raw, kind) when kind != :stage, do: {:ok, nil}

  defp fetch_phase(raw, :stage) do
    case Map.get(raw, "phase") do
      p when is_binary(p) ->
        try do
          {:ok, String.to_existing_atom(p)}
        rescue
          ArgumentError -> {:error, "invalid phase: #{inspect(p)}"}
        end

      _ ->
        {:error, "invalid phase: missing"}
    end
  end

  defp parse_io(list) when is_list(list) do
    Enum.map(list, fn entry ->
      %{type: Map.get(entry, "type"), labels: Map.get(entry, "labels", %{})}
    end)
  end

  defp parse_entrypoints(map) do
    %{
      perform: Map.get(map, "perform"),
      can_process: Map.get(map, "can_process")
    }
  end

  defp parse_config_schema(list) when is_list(list) do
    Enum.map(list, fn field ->
      %{
        key: field |> Map.fetch!("key") |> String.to_atom(),
        type: field |> Map.fetch!("type") |> String.to_atom(),
        default: Map.get(field, "default"),
        description: Map.get(field, "description", ""),
        required: Map.get(field, "required", false),
        options: Map.get(field, "options")
      }
    end)
  end
end
