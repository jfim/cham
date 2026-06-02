defmodule Cham.Plugin.ArtifactType do
  @moduledoc """
  The validated artifact-type vocabulary. A type is a first-class routing key
  that rides in `artifacts.labels["type"]` (no Phase 0 schema change). The
  vocabulary is a seeded set (config-extensible) unioned with every plugin's
  `declares_types`.
  """

  @default_seeded ~w(html_capture article_markdown audio thumbnail summary tags)

  @type vocabulary :: MapSet.t(String.t())

  @doc "The built-in seeded artifact types (config may extend this; see the registry)."
  @spec default_seeded() :: [String.t()]
  def default_seeded, do: @default_seeded

  @doc "Build the full vocabulary from a seeded list plus a list of `declares_types` lists."
  @spec build([String.t()], [[String.t()]]) :: vocabulary()
  def build(seeded, declared_lists) do
    declared = List.flatten(declared_lists)
    MapSet.new(seeded ++ declared)
  end

  @doc "Whether `type` is in the vocabulary."
  @spec known?(vocabulary(), String.t()) :: boolean()
  def known?(vocab, type), do: MapSet.member?(vocab, type)

  @doc "Validate a list of type names against the vocabulary. Reports the first unknown."
  @spec validate_types([String.t()], vocabulary()) :: :ok | {:error, String.t()}
  def validate_types(types, vocab) do
    case Enum.find(types, fn t -> not known?(vocab, t) end) do
      nil -> :ok
      bad -> {:error, "unknown artifact type: #{inspect(bad)}"}
    end
  end
end
