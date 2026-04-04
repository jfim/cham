defmodule Cham.Pipeline do
  alias Cham.Items
  alias Cham.Archive.{ArchiveManager, FilesystemManager}

  @doc """
  Submit a URL for processing. Creates an item, input artifact,
  and bootstrap directory. Returns {:ok, item} or {:error, changeset}.

  Options:
  - root: archive root directory (default: ".")
  - tags: list of user-supplied tags
  """
  def submit_url(url, opts \\ []) do
    root = Keyword.get(opts, :root, ".")
    tags = Keyword.get(opts, :tags, [])

    with {:ok, item} <- Items.create_item(%{url: url, tags: tags}),
         {:ok, item} <- setup_bootstrap(item, root),
         {:ok, _artifact} <- create_input_artifact(item, url) do
      Cham.Pipeline.Orchestrator.kick_off(item.id)
      {:ok, item}
    end
  end

  defp setup_bootstrap(item, root) do
    bootstrap_path = ArchiveManager.bootstrap_path(root, item.id)
    FilesystemManager.mkdir_p(bootstrap_path)
    Items.update_item(item, %{bootstrap_path: bootstrap_path})
  end

  defp create_input_artifact(item, url) do
    domain = extract_domain(url)
    start_ts = DateTime.utc_now() |> DateTime.to_unix()

    # Create the input stage directory
    {:ok, stage_dir} = ArchiveManager.create_stage_dir(item.bootstrap_path, "input")

    # Write artifact.json
    data = %{
      "stage" => %{"plugin_id" => "input", "start_ts" => start_ts, "end_ts" => start_ts},
      "artifacts" => [%{"labels" => %{"domain" => domain}, "filenames" => []}],
      "item_metadata" => %{"url" => url}
    }

    FilesystemManager.atomic_write(
      Path.join(stage_dir, "artifact.json"),
      Jason.encode!(data, pretty: true)
    )

    # Record in DB
    relative_path = "processing/#{Path.basename(stage_dir)}"

    Items.create_artifact(%{
      item_id: item.id,
      stage: "input",
      labels: %{"domain" => domain},
      filenames: [],
      path: relative_path,
      status: "produced"
    })
  end

  defp extract_domain(url) do
    uri = URI.parse(url)
    uri.host || "unknown"
  end
end
