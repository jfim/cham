defmodule Cham.Pipeline.DAG do
  alias Cham.Pipeline.LabelMatcher

  @doc """
  Find stages whose input matchers are satisfied by the available artifacts.
  A stage is ready when at least one artifact matches each of its input matchers.
  """
  def find_ready_stages(stages, available_artifacts) do
    Enum.filter(stages, fn stage ->
      stage.input_matchers != [] and
        Enum.any?(stage.input_matchers, fn matcher ->
          Enum.any?(available_artifacts, fn artifact ->
            LabelMatcher.matches?(artifact.labels, matcher)
          end)
        end)
    end)
  end

  @doc """
  Remove stages that have already been run (by plugin_id).
  """
  def exclude_already_run(stages, completed_stage_ids) do
    Enum.reject(stages, fn stage ->
      MapSet.member?(completed_stage_ids, stage.plugin_id)
    end)
  end

  @doc """
  Find the next stages to enqueue: stages that are ready and haven't run yet.
  """
  def find_next_stages(stages, available_artifacts, completed_stage_ids) do
    stages
    |> exclude_already_run(completed_stage_ids)
    |> find_ready_stages(available_artifacts)
  end

  @doc """
  Check if all reachable stages that produce `origin:original` artifacts have completed.
  A stage is reachable if its inputs are satisfied by available artifacts.
  Unreachable original-producing stages (e.g. extract_article for a video) don't block.
  """
  def all_originals_complete?(stages, available_artifacts, completed_stage_ids) do
    stages
    |> Enum.filter(&produces_originals?/1)
    |> Enum.filter(fn stage ->
      # Stage is relevant if it already completed OR its inputs are currently satisfied
      MapSet.member?(completed_stage_ids, stage.plugin_id) or
        inputs_satisfied?(stage, available_artifacts)
    end)
    |> Enum.all?(fn stage -> MapSet.member?(completed_stage_ids, stage.plugin_id) end)
  end

  defp inputs_satisfied?(stage, available_artifacts) do
    stage.input_matchers != [] and
      Enum.any?(stage.input_matchers, fn matcher ->
        Enum.any?(available_artifacts, fn artifact ->
          LabelMatcher.matches?(artifact.labels, matcher)
        end)
      end)
  end

  @doc """
  Find all stages that are transitively downstream of the given stage.
  Stage B is downstream of A if any of B's input_matchers could be satisfied
  by any of A's output_labels.
  """
  def find_downstream_stages(stages, stage_id) do
    stage = Enum.find(stages, &(&1.plugin_id == stage_id))

    if stage do
      do_find_downstream(stages, [stage], MapSet.new([stage_id]))
    else
      []
    end
  end

  defp do_find_downstream(_stages, [], _visited), do: []

  defp do_find_downstream(stages, frontier, visited) do
    # Collect all output labels from the frontier
    output_labels = Enum.flat_map(frontier, & &1.output_labels)

    # Find stages whose inputs could be satisfied by those outputs
    direct_dependents =
      Enum.filter(stages, fn candidate ->
        not MapSet.member?(visited, candidate.plugin_id) and
          Enum.any?(candidate.input_matchers, fn matcher ->
            Enum.any?(output_labels, fn labels ->
              LabelMatcher.matches?(labels, matcher)
            end)
          end)
      end)

    new_visited =
      Enum.reduce(direct_dependents, visited, fn s, acc ->
        MapSet.put(acc, s.plugin_id)
      end)

    direct_dependents ++ do_find_downstream(stages, direct_dependents, new_visited)
  end

  defp produces_originals?(stage) do
    Enum.any?(stage.output_labels, fn labels ->
      Map.get(labels, "origin") == "original"
    end)
  end
end
