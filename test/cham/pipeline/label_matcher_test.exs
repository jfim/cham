defmodule Cham.Pipeline.LabelMatcherTest do
  use ExUnit.Case, async: true

  alias Cham.Pipeline.LabelMatcher

  describe "matches?/2" do
    test "matches when artifact has all required labels" do
      artifact_labels = %{"origin" => "original", "format" => "text", "type" => "article"}
      matcher = %{"origin" => "original", "format" => "text"}
      assert LabelMatcher.matches?(artifact_labels, matcher)
    end

    test "matches when artifact has extra labels beyond matcher" do
      artifact_labels = %{"origin" => "original", "format" => "text", "extra" => "value"}
      matcher = %{"origin" => "original"}
      assert LabelMatcher.matches?(artifact_labels, matcher)
    end

    test "does not match when a required label is missing" do
      artifact_labels = %{"origin" => "original"}
      matcher = %{"origin" => "original", "format" => "text"}
      refute LabelMatcher.matches?(artifact_labels, matcher)
    end

    test "does not match when label value differs" do
      artifact_labels = %{"origin" => "derived", "format" => "text"}
      matcher = %{"origin" => "original", "format" => "text"}
      refute LabelMatcher.matches?(artifact_labels, matcher)
    end

    test "empty matcher matches any artifact" do
      artifact_labels = %{"origin" => "original", "format" => "video"}
      assert LabelMatcher.matches?(artifact_labels, %{})
    end

    test "negation: !value means label must not have that value" do
      artifact_labels = %{"format" => "video", "codec" => "h264"}
      matcher = %{"format" => "video", "codec" => "!webm"}
      assert LabelMatcher.matches?(artifact_labels, matcher)
    end

    test "negation: fails when label has the negated value" do
      artifact_labels = %{"format" => "video", "codec" => "webm"}
      matcher = %{"format" => "video", "codec" => "!webm"}
      refute LabelMatcher.matches?(artifact_labels, matcher)
    end

    test "negation: !value matches when label is absent" do
      artifact_labels = %{"format" => "video"}
      matcher = %{"format" => "video", "codec" => "!webm"}
      assert LabelMatcher.matches?(artifact_labels, matcher)
    end
  end

  describe "find_matching_artifacts/2" do
    test "returns artifacts that match any of the matchers" do
      artifacts = [
        %{labels: %{"origin" => "original", "format" => "text"}},
        %{labels: %{"origin" => "original", "format" => "video"}},
        %{labels: %{"origin" => "derived", "type" => "summary"}}
      ]

      matchers = [%{"origin" => "original", "format" => "text"}]
      matched = LabelMatcher.find_matching_artifacts(artifacts, matchers)
      assert length(matched) == 1
      assert hd(matched).labels["format"] == "text"
    end

    test "returns all artifacts matching any matcher in the list" do
      artifacts = [
        %{labels: %{"origin" => "original", "format" => "text"}},
        %{labels: %{"origin" => "original", "format" => "video"}},
        %{labels: %{"origin" => "derived", "type" => "summary"}}
      ]

      matchers = [
        %{"origin" => "original", "format" => "text"},
        %{"origin" => "original", "format" => "video"}
      ]

      matched = LabelMatcher.find_matching_artifacts(artifacts, matchers)
      assert length(matched) == 2
    end

    test "returns empty list when nothing matches" do
      artifacts = [%{labels: %{"origin" => "derived"}}]
      matchers = [%{"origin" => "original"}]
      assert LabelMatcher.find_matching_artifacts(artifacts, matchers) == []
    end
  end
end
