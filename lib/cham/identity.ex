defmodule Cham.Identity do
  @moduledoc """
  Versioned URL identity: normalization, hashing, and hash-set lookup.

  Normalization rules live in code with an explicit version so that any change
  is a reviewed code change (never a silent config edit that retroactively
  breaks stored hashes). `hash/1` hashes the string it is given — callers
  compose `hash(normalize(url))`.
  """

  alias Cham.Repo
  alias Cham.Archive.UrlIdentity

  @normalization_version 1

  # Denylist v1 — pure trackers only. Ambiguous load-bearing params (e.g. "ref")
  # are deliberately excluded.
  @denylist ~w(
    utm_source utm_medium utm_campaign utm_term utm_content utm_id
    fbclid gclid gbraid wbraid msclkid mc_eid mc_cid igshid _hsenc _hsmi
  )

  @doc "The current normalization rule version (stamped alongside persisted identity)."
  @spec normalization_version() :: pos_integer()
  def normalization_version, do: @normalization_version

  @doc "Normalize a URL per the version-1 rules. Deterministic."
  @spec normalize(String.t()) :: String.t()
  def normalize(url) when is_binary(url) do
    uri = URI.parse(url)

    scheme = uri.scheme && String.downcase(uri.scheme)
    host = uri.host && uri.host |> String.downcase() |> String.trim_trailing(".")
    port = drop_default_port(scheme, uri.port)

    path =
      case uri.path do
        nil -> "/"
        "" -> "/"
        p -> p
      end

    %{
      uri
      | scheme: scheme,
        host: host,
        port: port,
        path: path,
        query: normalize_query(uri.query),
        fragment: nil
    }
    |> URI.to_string()
  end

  @doc "Lowercase-hex SHA-256 of the given (already-normalized) URL string."
  @spec hash(String.t()) :: String.t()
  def hash(normalized_url) when is_binary(normalized_url) do
    :crypto.hash(:sha256, normalized_url) |> Base.encode16(case: :lower)
  end

  @doc """
  Resolve a URL to its item id via the `url_identities` hash set, or `nil`.
  Single index hit on `url_hash`.
  """
  @spec lookup_item_by_url(String.t()) :: Ecto.UUID.t() | nil
  def lookup_item_by_url(url) when is_binary(url) do
    h = hash(normalize(url))

    case Repo.get_by(UrlIdentity, url_hash: h) do
      nil -> nil
      %UrlIdentity{item_id: item_id} -> item_id
    end
  end

  defp drop_default_port("http", 80), do: nil
  defp drop_default_port("https", 443), do: nil
  defp drop_default_port(_scheme, port), do: port

  # Drop denylisted keys by raw key match; keep the rest in original order and
  # original encoding (split/rejoin on "&", no re-encoding).
  defp normalize_query(query) when query in [nil, ""], do: nil

  defp normalize_query(query) do
    kept =
      query
      |> String.split("&")
      |> Enum.reject(fn pair ->
        key = pair |> String.split("=", parts: 2) |> hd()
        key in @denylist
      end)

    case kept do
      [] -> nil
      _ -> Enum.join(kept, "&")
    end
  end
end
