defmodule Cham.Pipeline.DesiredStages do
  @moduledoc """
  Determines which stages should run for an item based on its content type
  and the desired artifacts configuration.

  Works backwards from desired artifact labels: finds which stages produce
  those artifacts, then which stages produce *their* inputs, recursively.
  Core stages (download, router) always run regardless.
  """

  alias Cham.Pipeline.LabelMatcher

  @core_stages MapSet.new([
                 "generic_download_url",
                 "content_type_router"
               ])

  @defaults %{
    "article" => [
      %{"type" => "content"},
      %{"type" => "summary"},
      %{"type" => "tags"},
      %{"type" => "clean_title"}
    ],
    "video" => [
      %{"type" => "transcript"},
      %{"type" => "summary"},
      %{"type" => "tags"},
      %{"type" => "clean_title"}
    ],
    "document" => [
      %{"type" => "content"},
      %{"type" => "summary"},
      %{"type" => "tags"},
      %{"type" => "clean_title"}
    ],
    "audio" => [
      %{"type" => "transcript"},
      %{"type" => "summary"},
      %{"type" => "tags"},
      %{"type" => "clean_title"}
    ]
  }

  @doc """
  Filter a list of ready stages to only those that are enabled and needed to
  produce the desired artifacts for the given content type.
  Core stages always pass through.
  If content_type is nil (not yet determined), all enabled stages pass.
  """
  def filter_stages(stages, nil, _all_stages) do
    filter_disabled(stages)
  end

  def filter_stages(ready_stages, content_type, all_stages) do
    desired = desired_artifacts(content_type)

    ready_stages = filter_disabled(ready_stages)

    if desired == [] do
      # No config for this content type — run everything
      ready_stages
    else
      required_ids = resolve_required_stages(desired, all_stages)

      Enum.filter(ready_stages, fn stage ->
        MapSet.member?(@core_stages, stage.plugin_id) or
          MapSet.member?(required_ids, stage.plugin_id)
      end)
    end
  end

  @doc """
  Given a list of desired artifact label matchers, work backwards through
  the stage graph to find all stages needed to produce them.
  """
  def resolve_required_stages(desired_labels, all_stages) do
    # Find stages that produce artifacts matching the desired labels
    producers = find_producers(desired_labels, all_stages)
    # Recursively find all upstream dependencies
    expand_dependencies(producers, all_stages, MapSet.new())
  end

  @doc "Returns the desired artifact labels for a content type."
  def desired_artifacts(content_type) do
    config = read_config()
    Map.get(config, content_type, Map.get(@defaults, content_type, []))
  end

  @doc "Returns the full defaults map."
  def defaults, do: @defaults

  # Find stages whose output_labels match any of the desired label matchers
  defp find_producers(desired_labels, all_stages) do
    Enum.filter(all_stages, fn stage ->
      Enum.any?(desired_labels, fn desired ->
        Enum.any?(stage.output_labels, fn output ->
          LabelMatcher.matches?(output, desired)
        end)
      end)
    end)
  end

  # Recursively expand: for each stage, find stages that produce its inputs
  defp expand_dependencies([], _all_stages, visited), do: visited

  defp expand_dependencies(frontier, all_stages, visited) do
    new_visited =
      Enum.reduce(frontier, visited, fn stage, acc ->
        MapSet.put(acc, stage.plugin_id)
      end)

    # Collect all input matchers from the frontier
    needed_inputs =
      frontier
      |> Enum.flat_map(& &1.input_matchers)
      |> Enum.reject(&(&1 == %{}))

    # Find stages that produce those inputs and haven't been visited
    upstream =
      Enum.filter(all_stages, fn stage ->
        not MapSet.member?(new_visited, stage.plugin_id) and
          Enum.any?(needed_inputs, fn needed ->
            Enum.any?(stage.output_labels, fn output ->
              LabelMatcher.matches?(output, needed)
            end)
          end)
      end)

    expand_dependencies(upstream, all_stages, new_visited)
  end

  defp filter_disabled(stages) do
    disabled = disabled_plugin_ids()

    if MapSet.size(disabled) == 0 do
      stages
    else
      Enum.reject(stages, fn stage -> MapSet.member?(disabled, stage.plugin_id) end)
    end
  end

  defp disabled_plugin_ids do
    case Cham.Config.Manager.read_all("enabled_plugins") do
      {:ok, values} ->
        values
        |> Enum.filter(fn {_k, v} -> v == false end)
        |> Enum.map(fn {k, _v} -> Atom.to_string(k) end)
        |> MapSet.new()

      {:error, _} ->
        MapSet.new()
    end
  end

  defp read_config do
    case Cham.Config.Manager.read_all("desired_artifacts") do
      {:ok, values} ->
        # Config stores comma-separated artifact type names per content type.
        # Convert to label matchers.
        values
        |> Enum.into(%{}, fn {k, v} ->
          types =
            v
            |> String.split(",")
            |> Enum.map(&String.trim/1)
            |> Enum.reject(&(&1 == ""))
            |> Enum.map(fn type -> %{"type" => type} end)

          {Atom.to_string(k), types}
        end)

      {:error, _} ->
        @defaults
    end
  end
end
