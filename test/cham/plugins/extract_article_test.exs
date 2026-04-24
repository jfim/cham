defmodule Cham.Plugins.ExtractArticleTest do
  use ExUnit.Case, async: true

  alias Cham.Plugins.ExtractArticle
  alias Cham.Plugins.ExtractArticle.ExtractStage

  describe "Plugin behaviour" do
    test "plugin_id" do
      assert ExtractArticle.plugin_id() == "extract_article"
    end

    test "name" do
      assert ExtractArticle.name() == "Article Extractor"
    end

    test "config_schema is empty" do
      assert ExtractArticle.config_schema() == []
    end

    test "init returns ok" do
      assert {:ok, %{}} = ExtractArticle.init(%{})
    end

    test "stages returns ExtractStage" do
      assert ExtractArticle.stages(%{}) == [ExtractStage]
    end
  end

  describe "Stage metadata" do
    test "name" do
      assert ExtractStage.name() == "Extract Article"
    end

    test "queue" do
      assert ExtractStage.queue() == :general
    end

    test "max_attempts" do
      assert ExtractStage.max_attempts() == 3
    end

    test "input_matchers" do
      assert ExtractStage.input_matchers() == [
               %{"origin" => "original", "format" => "text", "type" => "article"}
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
    test "returns ready when article artifact exists" do
      artifacts = [%{"origin" => "original", "format" => "text", "type" => "article"}]

      assert {:ready, [%{"origin" => "original", "format" => "text", "type" => "article"}], []} =
               ExtractStage.can_process?(artifacts)
    end

    test "returns not_applicable when no article artifact" do
      artifacts = [%{"origin" => "original", "format" => "text", "type" => "content"}]
      assert :not_applicable = ExtractStage.can_process?(artifacts)
    end

    test "returns not_applicable for empty artifacts" do
      assert :not_applicable = ExtractStage.can_process?([])
    end
  end
end

defmodule Cham.Plugins.ExtractArticleIntegrationTest do
  use ExUnit.Case, async: true

  @moduletag :integration

  alias Cham.Plugins.ExtractArticle.ExtractStage

  @sample_html """
  <!DOCTYPE html>
  <html>
  <head><title>Test Article</title></head>
  <body>
    <article>
      <h1>Test Article Title</h1>
      <p>By Test Author</p>
      <p>This is the main content of the article. It contains several paragraphs
      of text that should be extracted by trafilatura. The content needs to be
      substantial enough for trafilatura to consider it worth extracting.</p>
      <p>Here is another paragraph with more information about the topic at hand.
      This paragraph provides additional context and detail that makes the article
      more complete and informative for the reader.</p>
      <p>A third paragraph rounds out the article with concluding thoughts and
      final observations about the subject matter discussed above.</p>
    </article>
    <footer>Copyright 2024</footer>
  </body>
  </html>
  """

  setup do
    source_dir =
      Path.join(System.tmp_dir!(), "cham_extract_src_#{:erlang.unique_integer([:positive])}")

    working_dir =
      Path.join(System.tmp_dir!(), "cham_extract_dst_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(source_dir)
    File.mkdir_p!(working_dir)

    on_exit(fn ->
      File.rm_rf!(source_dir)
      File.rm_rf!(working_dir)
    end)

    {:ok, source_dir: source_dir, working_dir: working_dir}
  end

  test "perform/4 extracts article content from HTML", %{
    source_dir: source_dir,
    working_dir: working_dir
  } do
    html_file = Path.join(source_dir, "original.html")
    File.write!(html_file, @sample_html)

    input_artifacts = [
      %{
        labels: %{"origin" => "original", "format" => "text", "type" => "article"},
        filenames: ["original.html"],
        input_path: source_dir
      }
    ]

    assert {:ok, result} = ExtractStage.perform(input_artifacts, working_dir, [], "item-1")

    assert [artifact] = result.artifacts

    assert artifact.labels == %{
             "origin" => "original",
             "format" => "text",
             "type" => "content",
             "content_type" => "text/markdown"
           }

    assert artifact.filenames == ["content.md"]
    assert result.provenance == %{"tool" => "readability-lxml"}

    content_path = Path.join(working_dir, "content.md")
    assert File.exists?(content_path)

    content = File.read!(content_path)
    assert String.length(content) > 0
  end

  test "perform/4 returns error for empty HTML", %{
    source_dir: source_dir,
    working_dir: working_dir
  } do
    html_file = Path.join(source_dir, "empty.html")
    File.write!(html_file, "<html><body></body></html>")

    input_artifacts = [
      %{
        labels: %{"origin" => "original", "format" => "text", "type" => "article"},
        filenames: ["empty.html"],
        input_path: source_dir
      }
    ]

    assert {:error, _reason} = ExtractStage.perform(input_artifacts, working_dir, [], "item-1")
  end

  # Real-world page (nilenso blog "Trajectory shapes") closed <html> before the
  # <body>, which drops body content under lxml's parser. Readability-lxml then
  # returns only the <head>. Repairing via html5lib yields well-formed HTML so
  # readability can extract the article on retry.
  @malformed_html """
  <!doctype html>
  <html lang="en">
  <head><title>Broken Page</title></head>
  </html>

  <body>
    <article>
      <h1>Real Article Title</h1>
      <p>This is the main content of the article. It contains several paragraphs
      of substantive text. The content needs to be long enough that trafilatura
      picks it up as real article content rather than boilerplate noise.</p>
      <p>Here is another paragraph with more information about the topic at hand.
      This paragraph provides additional context and detail that makes the article
      more complete and informative for the reader.</p>
      <p>A third paragraph rounds out the article with concluding thoughts and
      final observations about the subject matter discussed above.</p>
    </article>
  </body>
  """

  test "perform/4 recovers article when <body> is misplaced after </html>", %{
    source_dir: source_dir,
    working_dir: working_dir
  } do
    html_file = Path.join(source_dir, "malformed.html")
    File.write!(html_file, @malformed_html)

    input_artifacts = [
      %{
        labels: %{"origin" => "original", "format" => "text", "type" => "article"},
        filenames: ["malformed.html"],
        input_path: source_dir
      }
    ]

    assert {:ok, _result} = ExtractStage.perform(input_artifacts, working_dir, [], "item-1")

    content = File.read!(Path.join(working_dir, "content.md"))
    assert content =~ "Real Article Title"
    assert content =~ "main content of the article"
  end
end
