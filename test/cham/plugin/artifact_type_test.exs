defmodule Cham.Plugin.ArtifactTypeTest do
  use ExUnit.Case, async: true
  alias Cham.Plugin.ArtifactType

  test "default seeded vocabulary includes the core types" do
    seeded = ArtifactType.default_seeded()
    assert "html_capture" in seeded
    assert "article_markdown" in seeded
    assert "thumbnail" in seeded
  end

  test "build/2 unions seeded types with declared types" do
    vocab =
      ArtifactType.build(["html_capture"], [["article_markdown"], ["audio", "html_capture"]])

    assert ArtifactType.known?(vocab, "html_capture")
    assert ArtifactType.known?(vocab, "article_markdown")
    assert ArtifactType.known?(vocab, "audio")
    refute ArtifactType.known?(vocab, "nope")
  end

  test "validate_types/2 returns :ok when all types are known" do
    vocab = ArtifactType.build(["html_capture", "article_markdown"], [])
    assert :ok == ArtifactType.validate_types(["html_capture", "article_markdown"], vocab)
  end

  test "validate_types/2 reports the first unknown type" do
    vocab = ArtifactType.build(["html_capture"], [])
    assert {:error, msg} = ArtifactType.validate_types(["html_capture", "ghost"], vocab)
    assert msg =~ "unknown artifact type: \"ghost\""
  end
end
