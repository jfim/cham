defmodule Cham.Pipeline.LabelMatcher do
  @doc """
  Check if an artifact's labels satisfy a matcher.
  A matcher is a map of required label key-value pairs.
  Values starting with "!" are negations: the artifact must NOT have that value.
  Missing labels in the artifact satisfy negation matchers.
  An empty matcher matches any artifact.
  """
  def matches?(artifact_labels, matcher) do
    Enum.all?(matcher, fn {key, pattern} ->
      match_label(artifact_labels, key, pattern)
    end)
  end

  @doc """
  Find all artifacts whose labels match any of the given matchers.
  Each matcher in the list is an alternative (OR). Within a matcher, all
  key-value pairs must match (AND).
  """
  def find_matching_artifacts(artifacts, matchers) do
    Enum.filter(artifacts, fn artifact ->
      Enum.any?(matchers, fn matcher ->
        matches?(artifact.labels, matcher)
      end)
    end)
  end

  defp match_label(artifact_labels, key, "!" <> negated_value) do
    case Map.get(artifact_labels, key) do
      nil -> true
      value -> value != negated_value
    end
  end

  defp match_label(artifact_labels, key, expected_value) do
    Map.get(artifact_labels, key) == expected_value
  end
end
