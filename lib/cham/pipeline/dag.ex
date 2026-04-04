defmodule Cham.Pipeline.DAG do
  alias Cham.Pipeline.LabelMatcher

  @doc """
  Find stages whose input matchers are satisfied by the available artifacts.
  A stage is ready when at least one artifact matches each of its input matchers.
  """
  def find_ready_stages(stages, available_artifacts) do
    Enum.filter(stages, fn stage ->
      stage.input_matchers != [] and
        Enum.all?(stage.input_matchers, fn matcher ->
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
  Check if all stages that produce `origin:original` artifacts have completed.
  This determines the archive threshold — when the item moves from bootstrap to archive.
  """
  def all_originals_complete?(stages, completed_stage_ids) do
    stages
    |> Enum.filter(&produces_originals?/1)
    |> Enum.all?(fn stage -> MapSet.member?(completed_stage_ids, stage.plugin_id) end)
  end

  defp produces_originals?(stage) do
    Enum.any?(stage.output_labels, fn labels ->
      Map.get(labels, "origin") == "original"
    end)
  end
end
