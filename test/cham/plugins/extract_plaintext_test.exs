defmodule Cham.Plugins.ExtractPlaintextTest do
  use ExUnit.Case, async: true

  alias Cham.Plugins.ExtractPlaintext
  alias Cham.Plugins.ExtractPlaintext.ExtractStage

  describe "Plugin behaviour" do
    test "plugin_id" do
      assert ExtractPlaintext.plugin_id() == "extract_plaintext"
    end

    test "config_schema is empty" do
      assert ExtractPlaintext.config_schema() == []
    end

    test "stages returns ExtractStage" do
      assert ExtractPlaintext.stages(%{}) == [ExtractStage]
    end
  end

  describe "Stage metadata" do
    test "input_matchers" do
      assert ExtractStage.input_matchers() == [
               %{"origin" => "original", "format" => "text", "type" => "plaintext"}
             ]
    end

    test "output_labels" do
      assert ExtractStage.output_labels() == [
               %{
                 "origin" => "original",
                 "format" => "text",
                 "type" => "content",
                 "content_type" => "text/markdown"
               }
             ]
    end
  end

  describe "can_process?/1" do
    test "ready when plaintext artifact exists" do
      artifacts = [%{"origin" => "original", "format" => "text", "type" => "plaintext"}]

      assert {:ready, [%{"origin" => "original", "format" => "text", "type" => "plaintext"}], []} =
               ExtractStage.can_process?(artifacts)
    end

    test "not_applicable when no plaintext artifact" do
      artifacts = [%{"origin" => "original", "format" => "text", "type" => "article"}]
      assert :not_applicable = ExtractStage.can_process?(artifacts)
    end

    test "not_applicable for empty artifacts" do
      assert :not_applicable = ExtractStage.can_process?([])
    end
  end

  describe "perform/4" do
    setup do
      source_dir =
        Path.join(System.tmp_dir!(), "cham_plain_src_#{:erlang.unique_integer([:positive])}")

      working_dir =
        Path.join(System.tmp_dir!(), "cham_plain_dst_#{:erlang.unique_integer([:positive])}")

      File.mkdir_p!(source_dir)
      File.mkdir_p!(working_dir)

      on_exit(fn ->
        File.rm_rf!(source_dir)
        File.rm_rf!(working_dir)
      end)

      {:ok, source_dir: source_dir, working_dir: working_dir}
    end

    test "references the source file via relative path without copying", %{
      source_dir: source_dir,
      working_dir: working_dir
    } do
      body = "Line one.\nLine two.\n\n# Not a heading, just text.\n"
      File.write!(Path.join(source_dir, "original.txt"), body)

      inputs = [
        %{
          labels: %{"origin" => "original", "format" => "text", "type" => "plaintext"},
          filenames: ["original.txt"],
          input_path: source_dir
        }
      ]

      assert {:ok, result} = ExtractStage.perform(inputs, working_dir, [], "item-1")

      assert [artifact] = result.artifacts

      assert artifact.labels == %{
               "origin" => "original",
               "format" => "text",
               "type" => "content",
               "content_type" => "text/markdown"
             }

      assert [ref_filename] = artifact.filenames
      assert String.ends_with?(ref_filename, "original.txt")
      assert result.provenance == %{"tool" => "passthrough"}

      # No copy should have been made into working_dir.
      refute File.exists?(Path.join(working_dir, "content.md"))
      refute File.exists?(Path.join(working_dir, "original.txt"))

      # The relative reference should resolve back to the source file.
      assert File.read!(Path.expand(ref_filename, working_dir)) == body
    end
  end
end
