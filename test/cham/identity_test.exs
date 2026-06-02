defmodule Cham.IdentityTest do
  use ExUnit.Case, async: true

  alias Cham.Identity

  describe "normalize/1 (version 1)" do
    test "lowercases scheme and host, strips trailing host dot" do
      assert Identity.normalize("HTTP://Example.COM./path") == "http://example.com/path"
    end

    test "drops the default port for http and https" do
      assert Identity.normalize("http://example.com:80/x") == "http://example.com/x"
      assert Identity.normalize("https://example.com:443/x") == "https://example.com/x"
    end

    test "keeps a non-default port" do
      assert Identity.normalize("http://example.com:8080/x") == "http://example.com:8080/x"
    end

    test "empty path becomes /" do
      assert Identity.normalize("https://example.com") == "https://example.com/"
    end

    test "does not strip a trailing slash on a non-root path" do
      assert Identity.normalize("https://example.com/a/") == "https://example.com/a/"
    end

    test "drops the fragment" do
      assert Identity.normalize("https://example.com/p#section") == "https://example.com/p"
    end

    test "strips each denylisted tracking param" do
      url =
        "https://example.com/p?utm_source=x&utm_medium=y&utm_campaign=z&utm_term=t" <>
          "&utm_content=c&utm_id=i&fbclid=f&gclid=g&gbraid=gb&wbraid=wb&msclkid=m" <>
          "&mc_eid=e&mc_cid=cc&igshid=ig&_hsenc=h1&_hsmi=h2"

      assert Identity.normalize(url) == "https://example.com/p"
    end

    test "keeps non-denylisted params in their original order" do
      assert Identity.normalize("https://example.com/p?b=2&a=1&utm_source=x&c=3") ==
               "https://example.com/p?b=2&a=1&c=3"
    end

    test "keeps a load-bearing 'ref' param (not in the denylist)" do
      assert Identity.normalize("https://example.com/p?ref=home") ==
               "https://example.com/p?ref=home"
    end

    test "is deterministic" do
      u = "https://example.com/a?x=1&y=2"
      assert Identity.normalize(u) == Identity.normalize(u)
    end

    test "drops an empty query (no trailing ?)" do
      assert Identity.normalize("https://example.com/p?") == "https://example.com/p"
    end
  end

  describe "hash/1" do
    test "is the lowercase hex SHA-256 of the given string" do
      expected = :crypto.hash(:sha256, "https://example.com/") |> Base.encode16(case: :lower)
      assert Identity.hash("https://example.com/") == expected
      assert Identity.hash("https://example.com/") =~ ~r/\A[0-9a-f]{64}\z/
    end

    test "differs for different inputs and is stable for the same input" do
      assert Identity.hash("a") == Identity.hash("a")
      refute Identity.hash("a") == Identity.hash("b")
    end
  end

  test "normalization_version/0 is 1" do
    assert Identity.normalization_version() == 1
  end
end

defmodule Cham.Identity.LookupTest do
  use Cham.DataCase, async: true

  alias Cham.Archive.{Item, UrlIdentity}
  alias Cham.Identity

  setup do
    {:ok, item} =
      %Item{}
      |> Item.create_changeset(%{
        slug: "ingest-a1b2c3d4",
        archive_path: "2026/06/01/ingest-a1b2c3d4",
        first_captured_at: ~U[2026-06-01 12:00:00Z]
      })
      |> Repo.insert()

    url = "https://example.com/known"

    {:ok, _} =
      %UrlIdentity{}
      |> UrlIdentity.changeset(%{
        item_id: item.id,
        url_hash: Identity.hash(Identity.normalize(url)),
        normalized_url: Identity.normalize(url),
        role: "submitted"
      })
      |> Repo.insert()

    %{item: item, url: url}
  end

  test "returns the item_id for a known URL (normalization-insensitive)", %{item: item, url: url} do
    # Trailing tracking param + uppercase host must resolve to the same hash.
    assert Identity.lookup_item_by_url("HTTPS://Example.com/known?utm_source=x") == item.id
    assert Identity.lookup_item_by_url(url) == item.id
  end

  test "returns nil for an unknown URL" do
    assert Identity.lookup_item_by_url("https://example.com/never-seen") == nil
  end
end
