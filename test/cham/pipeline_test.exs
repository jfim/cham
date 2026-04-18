defmodule Cham.PipelineTest do
  use Cham.DataCase

  alias Cham.Pipeline
  alias Cham.Items

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "cham_pipeline_test_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    %{root: tmp}
  end

  describe "cancel/1" do
    test "sets item status to cancelled", %{root: root} do
      {:ok, item} = Pipeline.submit_url("https://example.com/cancel-test", root: root)
      assert {:ok, updated} = Pipeline.cancel(item.id)
      assert updated.status == "cancelled"
    end

    test "returns error for already terminal item", %{root: root} do
      {:ok, item} = Pipeline.submit_url("https://example.com/cancel-terminal", root: root)
      {:ok, _} = Cham.Items.update_item(item, %{status: "complete"})
      assert {:error, :already_terminal} = Pipeline.cancel(item.id)
    end

    test "returns error for non-existent item" do
      assert {:error, :not_found} = Pipeline.cancel(Ecto.UUID.generate())
    end
  end

  describe "submit_url/2" do
    test "creates item in bootstrapping status", %{root: root} do
      assert {:ok, item} = Pipeline.submit_url("https://example.com/article", root: root)
      assert item.status == "bootstrapping"
      assert item.url == "https://example.com/article"
    end

    test "creates input artifact with domain label", %{root: root} do
      {:ok, item} = Pipeline.submit_url("https://example.com/article", root: root)
      [artifact] = Items.list_artifacts(item.id)
      assert artifact.stage == "input"
      assert artifact.labels["domain"] == "example.com"
    end

    test "creates bootstrap directory", %{root: root} do
      {:ok, item} = Pipeline.submit_url("https://example.com/article", root: root)
      assert item.bootstrap_path != nil
      assert File.dir?(item.bootstrap_path)
    end

    test "writes input artifact.json to bootstrap directory", %{root: root} do
      {:ok, item} = Pipeline.submit_url("https://example.com/article", root: root)
      # Check that processing/input-*/artifact.json exists
      stage_dirs = Cham.Archive.ArchiveManager.list_stage_dirs(item.bootstrap_path)
      assert length(stage_dirs) == 1
      assert Path.basename(hd(stage_dirs)) =~ "input-"
    end

    test "rejects duplicate URL", %{root: root} do
      {:ok, _} = Pipeline.submit_url("https://example.com/dup", root: root)
      assert {:error, changeset} = Pipeline.submit_url("https://example.com/dup", root: root)
      assert errors_on(changeset).url != nil
    end

    test "extracts domain from various URL formats", %{root: root} do
      {:ok, item} = Pipeline.submit_url("https://www.nebula.tv/videos/test", root: root)
      [artifact] = Items.list_artifacts(item.id)
      assert artifact.labels["domain"] == "www.nebula.tv"
    end
  end

  describe "reprocess/2 invalidate (per-item walker)" do
    # Regression: invalidating a stage used to cascade through the abstract
    # stage DAG, so a downloader with a match-all input_matcher (e.g.
    # download_ytdlp's [%{}]) was treated as downstream of every stage. The
    # walker now traverses the per-item artifact graph using temporal
    # ordering, so an upstream stage that ran *before* the invalidated one
    # is correctly excluded.
    test "does not delete the upstream download artifact when invalidating a late stage", %{
      root: root
    } do
      {:ok, item} = Pipeline.submit_url("https://example.com/late-invalidate", root: root)

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      # Simulate an item that has been processed end-to-end:
      # download (10:00) -> extract (10:01) -> transcribe (10:02) -> summarize (10:03)
      {:ok, download_art} =
        Items.create_artifact(%{
          item_id: item.id,
          stage: "download_ytdlp",
          labels: %{"origin" => "original", "type" => "initial_download", "format" => "video"},
          filenames: ["video.mp4"],
          path: "processing/download_ytdlp-1",
          status: "produced",
          started_at: DateTime.add(now, -3600),
          ended_at: DateTime.add(now, -3540)
        })

      {:ok, _summarize_art} =
        Items.create_artifact(%{
          item_id: item.id,
          stage: "summarize_ollama",
          labels: %{"origin" => "derived", "type" => "summary"},
          filenames: ["summary.md"],
          path: "processing/summarize_ollama-1",
          status: "produced",
          started_at: DateTime.add(now, -60),
          ended_at: now
        })

      {:ok, _} = Items.update_item(item, %{status: "complete", archive_path: root})

      assert {:ok, _} = Pipeline.reprocess(item.id, invalidate: ["summarize_ollama"])

      remaining = Items.list_artifacts(item.id)
      stages_left = Enum.map(remaining, & &1.stage)

      assert "download_ytdlp" in stages_left,
             "download_ytdlp artifact (id=#{download_art.id}) should not be deleted when invalidating a later stage"

      refute "summarize_ollama" in stages_left
    end
  end
end
