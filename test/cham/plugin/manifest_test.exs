defmodule Cham.Plugin.ManifestTest do
  use ExUnit.Case, async: true
  alias Cham.Plugin.Manifest

  @fixture "test/support/plugin_fixtures/extract_article/manifest.toml"

  test "parses a well-formed stage manifest from TOML" do
    {:ok, m} = Manifest.parse(@fixture)

    assert m.id == "extract_article"
    assert m.kind == :stage
    assert m.phase == :extract
    assert m.version == 3
    assert m.queue == "general"
    assert m.max_attempts == 3
    assert m.class == :subprocess
    assert m.source == {:dir, Path.dirname(@fixture)}
    assert m.inputs == [%{type: "html_capture", labels: %{"origin" => "original"}}]
    assert m.outputs == [%{type: "article_markdown", labels: %{"format" => "text"}}]
    assert m.declares_types == ["article_markdown"]
    assert m.entrypoints == %{perform: "sh perform.sh", can_process: "sh check.sh"}
    assert [%{key: :min_words, type: :integer, default: 20}] = m.config_schema
  end

  test "applies defaults for optional fields" do
    toml = """
    id = "minimal"
    kind = "stage"
    phase = "process"
    [entrypoints]
    perform = "true"
    """

    {:ok, m} = Manifest.parse_string(toml, {:dir, "/tmp/minimal"})
    assert m.version == 1
    assert m.max_attempts == 3
    assert m.queue == "general"
    assert m.inputs == []
    assert m.outputs == []
    assert m.declares_types == []
    assert m.config_schema == []
    assert m.entrypoints.can_process == nil
  end

  test "rejects an unknown kind" do
    toml = ~s(id = "x"\nkind = "wizard"\n[entrypoints]\nperform = "true"\n)
    assert {:error, msg} = Manifest.parse_string(toml, {:dir, "/tmp/x"})
    assert msg =~ "unknown kind"
  end

  test "rejects an invalid phase for a stage" do
    toml = ~s(id = "x"\nkind = "stage"\nphase = "launch"\n[entrypoints]\nperform = "true"\n)
    assert {:error, msg} = Manifest.parse_string(toml, {:dir, "/tmp/x"})
    assert msg =~ "invalid phase"
  end

  test "rejects a stage missing the perform entrypoint" do
    toml = ~s(id = "x"\nkind = "stage"\nphase = "extract"\n)
    assert {:error, msg} = Manifest.parse_string(toml, {:dir, "/tmp/x"})
    assert msg =~ "missing required entrypoint: perform"
  end

  test "accepts reserved kinds subscriber and integration" do
    for kind <- ~w(subscriber integration) do
      toml = ~s(id = "x"\nkind = "#{kind}"\n[entrypoints]\nperform = "true"\n)
      assert {:ok, m} = Manifest.parse_string(toml, {:dir, "/tmp/x"})
      assert m.kind == String.to_existing_atom(kind)
    end
  end

  test "returns an error for malformed TOML" do
    assert {:error, _} = Manifest.parse_string("id = = =", {:dir, "/tmp/bad"})
  end

  test "accepts the subscription kind with a perform entrypoint" do
    toml = ~s(id = "feed"\nkind = "subscription"\n[entrypoints]\nperform = "true"\n)
    assert {:ok, m} = Manifest.parse_string(toml, {:dir, "/tmp/feed"})
    assert m.kind == :subscription
    assert m.phase == nil
  end

  test "rejects a subprocess subscription missing the perform entrypoint" do
    toml = ~s(id = "feed"\nkind = "subscription"\n)
    assert {:error, msg} = Manifest.parse_string(toml, {:dir, "/tmp/feed"})
    assert msg =~ "missing required entrypoint: perform"
  end

  test "parse/1 returns an error for a nonexistent file" do
    assert {:error, msg} =
             Manifest.parse("test/support/plugin_fixtures/does_not_exist/manifest.toml")

    assert msg =~ "cannot read"
  end

  test "rejects a config_schema entry missing key or type" do
    toml =
      ~s(id = "x"\nkind = "stage"\nphase = "extract"\n[entrypoints]\nperform = "true"\n[[config_schema]]\ndefault = 1\n)

    assert {:error, msg} = Manifest.parse_string(toml, {:dir, "/tmp/x"})
    assert msg =~ "config_schema"
  end
end
