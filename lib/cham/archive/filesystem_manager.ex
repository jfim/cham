defmodule Cham.Archive.FilesystemManager do
  @moduledoc """
  Pure filesystem operations with no knowledge of archive layout or artifact semantics.
  """

  @doc """
  Creates nested directories, succeeding if they already exist.
  """
  def mkdir_p(path) do
    File.mkdir_p(path)
  end

  @doc """
  Writes file content atomically using a temp file and rename.
  Creates parent directories if needed.
  """
  def atomic_write(path, content) do
    dir = Path.dirname(path)
    File.mkdir_p!(dir)
    tmp_path = path <> ".tmp.#{:erlang.unique_integer([:positive])}"

    with :ok <- File.write(tmp_path, content) do
      File.rename(tmp_path, path)
    end
  end

  @doc """
  Moves a file or directory tree from `src` to `dst`.
  Creates parent directories for the destination.
  Falls back to copy+delete for cross-device moves.
  """
  def move(src, dst) do
    File.mkdir_p!(Path.dirname(dst))

    case File.rename(src, dst) do
      :ok ->
        :ok

      {:error, :exdev} ->
        if File.dir?(src) do
          File.cp_r!(src, dst)
          File.rm_rf!(src)
        else
          File.cp!(src, dst)
          File.rm!(src)
        end

        :ok
    end
  end
end
