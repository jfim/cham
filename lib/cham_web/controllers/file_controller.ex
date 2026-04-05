defmodule ChamWeb.FileController do
  use ChamWeb, :controller

  alias Cham.Items

  @doc """
  Serve a file from an item's archive. Supports HTTP Range requests for media streaming.
  """
  def show(conn, %{"id" => id, "filename" => filename_parts}) do
    filename = Enum.join(filename_parts, "/")

    with :ok <- validate_filename(filename),
         {:ok, item} <- Items.get_item_by_slug_or_id(id),
         {:ok, file_path} <- resolve_file_path(item, filename),
         {:ok, stat} <- file_stat(file_path) do
      mime = MIME.from_path(filename)
      serve_file(conn, file_path, stat.size, mime)
    else
      {:error, :invalid_filename} ->
        conn |> send_resp(400, "invalid filename") |> halt()

      {:error, :not_found} ->
        conn |> send_resp(404, "not found") |> halt()

      {:error, :file_not_found} ->
        conn |> send_resp(404, "file not found") |> halt()
    end
  end

  defp validate_filename(filename) do
    if String.contains?(filename, "..") do
      {:error, :invalid_filename}
    else
      :ok
    end
  end

  defp resolve_file_path(item, filename) do
    item_dir = item.archive_path || item.bootstrap_path

    if is_nil(item_dir) do
      {:error, :file_not_found}
    else
      artifacts = Items.list_artifacts(item.id)

      # Search artifacts for a matching filename
      result =
        Enum.find_value(artifacts, fn artifact ->
          Enum.find_value(artifact.filenames, fn af ->
            # The artifact filename may be a relative path (e.g. "../other-stage/file.pdf")
            # or a bare name (e.g. "content.md"). Match on the basename.
            if Path.basename(af) == Path.basename(filename) do
              full_path = Path.expand(Path.join([item_dir, artifact.path, af]))

              # Verify the resolved path is still under item_dir (traversal protection)
              expanded_item_dir = Path.expand(item_dir)

              if String.starts_with?(full_path, expanded_item_dir <> "/") or
                   String.starts_with?(full_path, Path.expand(item_dir <> "/..")) do
                full_path
              end
            end
          end)
        end)

      # Also check for direct path under item_dir as fallback
      result =
        result ||
          (fn ->
             direct = Path.expand(Path.join(item_dir, filename))
             expanded_item_dir = Path.expand(item_dir)

             if String.starts_with?(direct, expanded_item_dir <> "/") and File.exists?(direct) do
               direct
             end
           end).()

      if result, do: {:ok, result}, else: {:error, :file_not_found}
    end
  end

  defp file_stat(path) do
    case File.stat(path) do
      {:ok, stat} -> {:ok, stat}
      {:error, _} -> {:error, :file_not_found}
    end
  end

  defp serve_file(conn, path, file_size, mime) do
    case get_req_header(conn, "range") do
      ["bytes=" <> range_spec | _] ->
        serve_range(conn, path, file_size, mime, range_spec)

      _ ->
        conn
        |> put_resp_header("content-type", mime)
        |> put_resp_header("content-length", Integer.to_string(file_size))
        |> put_resp_header("accept-ranges", "bytes")
        |> send_file(200, path)
    end
  end

  defp serve_range(conn, path, file_size, mime, range_spec) do
    case parse_range(range_spec, file_size) do
      {:ok, range_start, range_end} ->
        length = range_end - range_start + 1

        conn
        |> put_resp_header("content-type", mime)
        |> put_resp_header("content-length", Integer.to_string(length))
        |> put_resp_header("content-range", "bytes #{range_start}-#{range_end}/#{file_size}")
        |> put_resp_header("accept-ranges", "bytes")
        |> send_file(206, path, range_start, length)

      :error ->
        conn
        |> put_resp_header("content-range", "bytes */#{file_size}")
        |> send_resp(416, "range not satisfiable")
        |> halt()
    end
  end

  defp parse_range(spec, file_size) do
    case String.split(spec, "-", parts: 2) do
      [start_str, ""] when start_str != "" ->
        # "500-" means from byte 500 to end
        start = String.to_integer(start_str)
        if start < file_size, do: {:ok, start, file_size - 1}, else: :error

      ["", suffix_str] when suffix_str != "" ->
        # "-500" means last 500 bytes
        suffix = String.to_integer(suffix_str)
        start = max(file_size - suffix, 0)
        {:ok, start, file_size - 1}

      [start_str, end_str] when start_str != "" and end_str != "" ->
        range_start = String.to_integer(start_str)
        range_end = min(String.to_integer(end_str), file_size - 1)

        if range_start <= range_end and range_start < file_size do
          {:ok, range_start, range_end}
        else
          :error
        end

      _ ->
        :error
    end
  rescue
    ArgumentError -> :error
  end
end
