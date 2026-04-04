defmodule Cham.Config.TomlEncoder do
  @doc """
  Encode a map of %{section_name => %{key => value}} into a TOML string.
  Sections are sorted alphabetically. Keys within sections are sorted alphabetically.
  """
  def encode(config) when config == %{}, do: "\n"

  def encode(config) do
    config
    |> Enum.sort_by(fn {section, _} -> section end)
    |> Enum.map_join("\n\n", fn {section, values} ->
      header = "[#{section}]"

      lines =
        values
        |> Enum.sort_by(fn {key, _} -> key end)
        |> Enum.map_join("\n", fn {key, value} ->
          "#{key} = #{encode_value(value)}"
        end)

      "#{header}\n#{lines}"
    end)
    |> Kernel.<>("\n")
  end

  defp encode_value(value) when is_binary(value), do: ~s("#{escape_string(value)}")
  defp encode_value(value) when is_integer(value), do: Integer.to_string(value)
  defp encode_value(value) when is_float(value), do: Float.to_string(value)
  defp encode_value(true), do: "true"
  defp encode_value(false), do: "false"

  defp encode_value(value) when is_list(value) do
    inner = Enum.map_join(value, ", ", &encode_value/1)
    "[#{inner}]"
  end

  defp encode_value(value) when is_atom(value), do: ~s("#{Atom.to_string(value)}")

  defp escape_string(str) do
    str
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
  end
end
