defmodule Cham.Items.DeleteTest do
  use Cham.DataCase

  alias Cham.Items

  setup do
    tmp = Path.join(System.tmp_dir!(), "cham_delete_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    %{tmp: tmp}
  end

  describe "delete_item_with_files/2" do
    test "deletes item and associated files", %{tmp: tmp} do
      item_dir = Path.join(tmp, "test-item")
      File.mkdir_p!(item_dir)
      File.write!(Path.join(item_dir, "test.txt"), "hello")

      {:ok, item} = Items.create_item(%{url: "https://example.com/delete-1"})
      {:ok, item} = Items.update_item(item, %{archive_path: item_dir})

      {:ok, _} =
        Items.create_artifact(%{
          item_id: item.id,
          stage: "input",
          labels: %{},
          path: "processing/input",
          filenames: []
        })

      assert :ok = Items.delete_item_with_files(item)
      assert Items.get_item(item.id) == nil
      refute File.dir?(item_dir)
    end

    test "deletes item with keep_files option", %{tmp: tmp} do
      item_dir = Path.join(tmp, "test-item-keep")
      File.mkdir_p!(item_dir)
      File.write!(Path.join(item_dir, "test.txt"), "hello")

      {:ok, item} = Items.create_item(%{url: "https://example.com/delete-2"})
      {:ok, item} = Items.update_item(item, %{archive_path: item_dir})

      assert :ok = Items.delete_item_with_files(item, keep_files: true)
      assert Items.get_item(item.id) == nil
      assert File.dir?(item_dir)
    end

    test "deletes item with bootstrap_path when no archive_path", %{tmp: tmp} do
      item_dir = Path.join(tmp, "bootstrap-item")
      File.mkdir_p!(item_dir)

      {:ok, item} = Items.create_item(%{url: "https://example.com/delete-3"})
      {:ok, item} = Items.update_item(item, %{bootstrap_path: item_dir})

      assert :ok = Items.delete_item_with_files(item)
      assert Items.get_item(item.id) == nil
      refute File.dir?(item_dir)
    end

    test "deletes item when no paths exist" do
      {:ok, item} = Items.create_item(%{url: "https://example.com/delete-4"})

      assert :ok = Items.delete_item_with_files(item)
      assert Items.get_item(item.id) == nil
    end
  end

  describe "list_stage_executions/1" do
    test "returns stage executions for an item" do
      {:ok, item} = Items.create_item(%{url: "https://example.com/exec-1"})

      Cham.Repo.insert!(%Cham.JobTracking.StageExecution{
        item_id: item.id,
        stage: "download",
        status: "completed",
        attempt: 1,
        started_at: DateTime.truncate(DateTime.utc_now(), :second),
        ended_at: DateTime.truncate(DateTime.utc_now(), :second),
        duration_ms: 500
      })

      executions = Items.list_stage_executions(item.id)
      assert length(executions) == 1
      assert hd(executions).stage == "download"
    end
  end
end
