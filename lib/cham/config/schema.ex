defmodule Cham.Config.Schema do
  @doc """
  Validate a map of string-keyed values against a schema.
  Returns {:ok, atom_keyed_map} or {:error, [error_strings]}.
  Missing keys get their defaults. Unknown keys are ignored.
  """
  def validate(values, schema) do
    results =
      Enum.map(schema, fn field ->
        key_str = Atom.to_string(field.key)
        raw = Map.get(values, key_str, :missing)

        case raw do
          :missing ->
            {:ok, field.key, field.default}

          value ->
            case validate_field(value, field) do
              {:ok, coerced} -> {:ok, field.key, coerced}
              {:error, msg} -> {:error, msg}
            end
        end
      end)

    errors = for {:error, msg} <- results, do: msg

    if errors == [] do
      validated = for {:ok, key, value} <- results, into: %{}, do: {key, value}
      {:ok, validated}
    else
      {:error, errors}
    end
  end

  defp validate_field(value, field) do
    with {:ok, coerced} <- check_type(value, field.type, field.key) do
      check_options(coerced, field)
    end
  end

  defp check_type(value, :string, _key) when is_binary(value), do: {:ok, value}
  defp check_type(value, :integer, _key) when is_integer(value), do: {:ok, value}
  defp check_type(value, :float, _key) when is_float(value), do: {:ok, value}
  defp check_type(value, :float, _key) when is_integer(value), do: {:ok, value / 1}
  defp check_type(value, :boolean, _key) when is_boolean(value), do: {:ok, value}
  defp check_type(value, :atom, _key) when is_atom(value), do: {:ok, value}
  defp check_type(value, :atom, _key) when is_binary(value), do: {:ok, String.to_atom(value)}
  defp check_type(value, :url, _key) when is_binary(value), do: {:ok, value}

  defp check_type(value, type, key),
    do: {:error, "expected #{type} for :#{key}, got #{inspect(value)}"}

  defp check_options(value, %{options: options, key: key}) when is_list(options) do
    if value in options do
      {:ok, value}
    else
      {:error,
       "invalid value for :#{key}, got #{inspect(value)}, expected one of #{inspect(options)}"}
    end
  end

  defp check_options(value, _field), do: {:ok, value}
end
