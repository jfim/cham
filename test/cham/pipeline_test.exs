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
end
