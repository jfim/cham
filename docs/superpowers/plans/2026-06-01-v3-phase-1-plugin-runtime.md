# v3 Phase 1 — Plugin Runtime Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the v3 plugin runtime — a manifest-described, one-shot invocation contract that lets Elixir modules (fast path) or external subprocesses (any language) be registered, described, and invoked under one wire protocol.

**Architecture:** A static TOML/behaviour **manifest** describes each plugin (kind × class). A canonical **wire protocol** (`request.json` in / `output.json` out via a shared `working_dir`, optional JSONL progress on stdout) is shared by two **transports**: in-process Elixir and external subprocess. A **registry** scans/validates manifests, builds the artifact-type vocabulary, registers per-plugin config, and exposes a catalog + dispatch table. A **runtime** dispatches an invocation by class and returns a decoded result. The `stage` kind is built in full; `subscription` gets its invocation contract; `subscriber`/`integration` are reserved.

**Tech Stack:** Elixir 1.19 / OTP 28, Phoenix 1.7, `toml` (manifests), `Jason` (wire JSON), Erlang `Port` (subprocess transport), `Cham.EventBus` (progress forwarding), `Cham.Config.Manager` (per-plugin config), `Cham.Archive.Layout` (working dirs).

**Spec:** `docs/superpowers/specs/2026-06-01-v3-plugin-runtime-design.md` (approved).
**Reconciliation:** `docs/superpowers/specs/2026-06-01-v3-ingestion-reconciliation-and-sequencing.md` (Part D, Phase 1).

**Resolved open questions (§12, confirmed with user 2026-06-01):**
- **Plugins root:** a single configurable dir, defaulting to `plugins/` at the repo root; tests override it with a tmp dir.
- **Config timing:** the runtime takes `config` as a caller-supplied passthrough and serializes it verbatim; it does NOT read `Config.Manager` itself (the Phase 4 executor becomes the caller that resolves `plugins.<id>`).
- **In-process API:** the behaviour requires `manifest/0` returning the same `Cham.Plugin.Manifest` struct that subprocess plugins parse from TOML (single source of truth), plus `perform/2` and optional `can_process/1`.

---

## File Structure

**New modules (all under `lib/cham/plugin/`):**
- `manifest.ex` — `Cham.Plugin.Manifest`: the parsed-manifest struct + TOML parse + structural validation (kind/phase/entrypoints). Type-vocabulary validation is the registry's job.
- `artifact_type.ex` — `Cham.Plugin.ArtifactType`: build the validated vocabulary (seeded ∪ declared) and validate type lists.
- `wire_protocol.ex` — `Cham.Plugin.WireProtocol`: request structs (`PerformRequest`, `CanProcessRequest`, `SubscriptionRequest`), result structs (`StageResult`, `SubscriptionResult`), JSON encode of requests + decode of results, and the `waiting_for_input → failed(:unsupported)` mapping.
- `events.ex` — `Cham.Plugin.Events`: the `%PluginEvent{}` struct forwarded to the EventBus.
- `stage.ex` — `Cham.Plugin.Stage`: in-process stage behaviour (`manifest/0`, `perform/2`, optional `can_process/1`).
- `subscription.ex` — `Cham.Plugin.Subscription`: in-process subscription behaviour (`manifest/0`, `perform/2`).
- `transport/in_process.ex` — `Cham.Plugin.Transport.InProcess`: invoke the behaviour module directly, return the result struct, forward `emit` events.
- `transport/subprocess.ex` — `Cham.Plugin.Transport.Subprocess`: own `Port` handling (line-buffered stdout JSONL, stderr→log redirect, `output.json` read, crash/timeout → `failed(:error)`).
- `registry.ex` — `Cham.Plugin.Registry`: GenServer. Scan plugins root, parse+validate manifests, register compile-time in-process modules, build vocabulary, validate types, register `config_schema` into `plugins.<id>`, build catalog + dispatch table, skip disabled/malformed.
- `runtime.ex` — `Cham.Plugin.Runtime`: the unified `run/3` entry point; dispatch by class; manage `working_dir`; return decoded result.

**Modified:**
- `lib/cham/archive/layout.ex` — add `stage_path/2` (relative `stages/<stage_id>-<ts>`), mirroring `snapshot_path/1`.
- `lib/cham/application.ex` — add `Cham.Plugin.Registry` to the supervision tree; register the `plugins` config namespace (seeded artifact types + disabled list); register the compile-time in-process module list at startup.
- `.sobelow-conf` — drop the now-deleted `script_runner.ex` entry (Task 0); add `transport/subprocess.ex` + `registry.ex` to the by-design Traversal/command allowlist (Task 11).

**Removed (dead v2 code, Task 0):**
- `lib/cham/script_runner.ex`, `lib/cham/script_runner/events.ex`, `test/cham/script_runner_test.exs` — the v2 subprocess primitive. Confirmed to have zero callers after the Plan 0a teardown; `Cham.Plugin.Transport.Subprocess` is its v3 replacement (one canonical port-spawning path for all plugins).

**Test files mirror each module under `test/cham/plugin/`, plus a subprocess fixture tree under `test/support/plugin_fixtures/`.**

---

## Task 0: Remove the dead v2 ScriptRunner

**Files:**
- Delete: `lib/cham/script_runner.ex`
- Delete: `lib/cham/script_runner/events.ex`
- Delete: `test/cham/script_runner_test.exs`
- Modify: `.sobelow-conf` (drop the `script_runner.ex` ignore entry)

`Cham.ScriptRunner` is the v2 subprocess primitive. After the Plan 0a teardown it has **zero callers** (verified: the only references are within its own module, events file, and test). The v3 plugin runtime spawns every subprocess through `Cham.Plugin.Transport.Subprocess` (Task 6), which is `ScriptRunner`'s replacement — so keeping the old one would just be a second, divergent port implementation. Remove it first so there is exactly one subprocess path in the tree.

- [ ] **Step 1: Re-verify there are no callers**

Run: `grep -rn "ScriptRunner\|ScriptOutput\|ScriptExited\|ScriptTimeout" lib/ test/ | grep -v "lib/cham/script_runner" | grep -v "test/cham/script_runner_test"`
Expected: no output (the only references are the files being deleted).

- [ ] **Step 2: Delete the files**

```bash
git rm lib/cham/script_runner.ex lib/cham/script_runner/events.ex test/cham/script_runner_test.exs
```

- [ ] **Step 3: Drop the sobelow allowlist entry**

In `.sobelow-conf`, remove the `"lib/cham/script_runner.ex"` line from `ignore_files`, and delete its line from the justifying comment block (the `- lib/cham/script_runner.ex   (local script log file write)` line). Leave the other entries untouched.

- [ ] **Step 4: Verify the tree still compiles and the gate is clean**

Run: `mix compile --warnings-as-errors`
Expected: clean compile (no references dangling).

Run: `mix test`
Expected: PASS — the suite shrinks by the deleted ScriptRunner tests, no failures.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "chore(v3): remove dead v2 ScriptRunner (replaced by Cham.Plugin.Transport.Subprocess)"
```

---

## Task 1: Manifest struct + TOML parse + structural validation

**Files:**
- Create: `lib/cham/plugin/manifest.ex`
- Test: `test/cham/plugin/manifest_test.exs`
- Fixture: `test/support/plugin_fixtures/extract_article/manifest.toml`

- [ ] **Step 1: Write the fixture manifest**

Create `test/support/plugin_fixtures/extract_article/manifest.toml`:

```toml
id = "extract_article"
kind = "stage"
phase = "extract"
version = 3
queue = "general"
max_attempts = 3

inputs  = [ { type = "html_capture", labels = { origin = "original" } } ]
outputs = [ { type = "article_markdown", labels = { format = "text" } } ]

declares_types = ["article_markdown"]

[entrypoints]
perform = "sh perform.sh"
can_process = "sh check.sh"

[[config_schema]]
key = "min_words"
type = "integer"
default = 20
description = "Minimum word count to treat content as an article."
required = false
```

- [ ] **Step 2: Write the failing test**

```elixir
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
end
```

- [ ] **Step 3: Run test to verify it fails**

Run: `mix test test/cham/plugin/manifest_test.exs`
Expected: FAIL — `Cham.Plugin.Manifest` is undefined.

- [ ] **Step 4: Implement the module**

```elixir
defmodule Cham.Plugin.Manifest do
  @moduledoc """
  The parsed, static, declarative self-description of a plugin. Source of truth
  for everything except the live `can_process` probe. Parsed from `manifest.toml`
  (subprocess plugins) or returned by an in-process behaviour's `manifest/0`.
  """

  @kinds [:stage, :subscription, :subscriber, :integration]
  @phases [:bootstrap, :extract, :process]

  @type io_decl :: %{type: String.t(), labels: map()}
  @type t :: %__MODULE__{
          id: String.t(),
          kind: atom(),
          phase: atom() | nil,
          version: pos_integer(),
          queue: String.t(),
          max_attempts: pos_integer(),
          inputs: [io_decl()],
          outputs: [io_decl()],
          declares_types: [String.t()],
          entrypoints: %{perform: String.t() | nil, can_process: String.t() | nil},
          config_schema: [map()],
          class: :subprocess | :in_process,
          source: {:dir, String.t()} | {:module, module()}
        }

  @enforce_keys [:id, :kind, :class, :source]
  defstruct id: nil,
            kind: nil,
            phase: nil,
            version: 1,
            queue: "general",
            max_attempts: 3,
            inputs: [],
            outputs: [],
            declares_types: [],
            entrypoints: %{perform: nil, can_process: nil},
            config_schema: [],
            class: nil,
            source: nil

  @doc "Known plugin kinds."
  def kinds, do: @kinds

  @doc "Parse and validate a `manifest.toml` file. `source` is `{:dir, dir}`."
  @spec parse(String.t()) :: {:ok, t()} | {:error, String.t()}
  def parse(path) do
    case File.read(path) do
      {:ok, content} -> parse_string(content, {:dir, Path.dirname(path)})
      {:error, reason} -> {:error, "cannot read #{path}: #{inspect(reason)}"}
    end
  end

  @doc "Parse and validate a TOML string for a subprocess plugin."
  @spec parse_string(String.t(), {:dir, String.t()}) :: {:ok, t()} | {:error, String.t()}
  def parse_string(content, {:dir, dir}) do
    with {:ok, raw} <- decode(content),
         {:ok, kind} <- fetch_kind(raw),
         {:ok, phase} <- fetch_phase(raw, kind) do
      manifest = %__MODULE__{
        id: Map.get(raw, "id"),
        kind: kind,
        phase: phase,
        version: Map.get(raw, "version", 1),
        queue: Map.get(raw, "queue", "general"),
        max_attempts: Map.get(raw, "max_attempts", 3),
        inputs: parse_io(Map.get(raw, "inputs", [])),
        outputs: parse_io(Map.get(raw, "outputs", [])),
        declares_types: Map.get(raw, "declares_types", []),
        entrypoints: parse_entrypoints(Map.get(raw, "entrypoints", %{})),
        config_schema: parse_config_schema(Map.get(raw, "config_schema", [])),
        class: :subprocess,
        source: {:dir, dir}
      }

      validate(manifest)
    end
  end

  @doc "Validate an already-built manifest (used for in-process `manifest/0` too)."
  @spec validate(t()) :: {:ok, t()} | {:error, String.t()}
  def validate(%__MODULE__{} = m) do
    cond do
      m.id in [nil, ""] -> {:error, "missing id"}
      m.kind not in @kinds -> {:error, "unknown kind: #{inspect(m.kind)}"}
      m.kind == :stage and m.phase not in @phases -> {:error, "invalid phase: #{inspect(m.phase)}"}
      m.kind in [:stage, :subscription] and is_nil(m.entrypoints.perform) and m.class == :subprocess ->
        {:error, "missing required entrypoint: perform"}
      true -> {:ok, m}
    end
  end

  defp decode(content) do
    case Toml.decode(content) do
      {:ok, map} -> {:ok, map}
      {:error, reason} -> {:error, "malformed TOML: #{inspect(reason)}"}
    end
  end

  defp fetch_kind(raw) do
    case Map.get(raw, "kind") do
      k when is_binary(k) ->
        try do
          {:ok, String.to_existing_atom(k)}
        rescue
          ArgumentError -> {:error, "unknown kind: #{inspect(k)}"}
        end

      _ ->
        {:error, "missing kind"}
    end
    |> case do
      {:ok, atom} when atom in @kinds -> {:ok, atom}
      {:ok, atom} -> {:error, "unknown kind: #{inspect(atom)}"}
      err -> err
    end
  end

  defp fetch_phase(_raw, kind) when kind != :stage, do: {:ok, nil}

  defp fetch_phase(raw, :stage) do
    case Map.get(raw, "phase") do
      p when is_binary(p) ->
        try do
          {:ok, String.to_existing_atom(p)}
        rescue
          ArgumentError -> {:error, "invalid phase: #{inspect(p)}"}
        end

      _ ->
        {:error, "invalid phase: missing"}
    end
  end

  defp parse_io(list) when is_list(list) do
    Enum.map(list, fn entry ->
      %{type: Map.get(entry, "type"), labels: Map.get(entry, "labels", %{})}
    end)
  end

  defp parse_entrypoints(map) do
    %{
      perform: Map.get(map, "perform"),
      can_process: Map.get(map, "can_process")
    }
  end

  defp parse_config_schema(list) when is_list(list) do
    Enum.map(list, fn field ->
      %{
        key: field |> Map.fetch!("key") |> String.to_atom(),
        type: field |> Map.fetch!("type") |> String.to_atom(),
        default: Map.get(field, "default"),
        description: Map.get(field, "description", ""),
        required: Map.get(field, "required", false),
        options: Map.get(field, "options")
      }
    end)
  end
end
```

Note: `config_schema` keys/types use `String.to_atom/1` because they come from a trusted on-disk manifest authored by the operator (not remote input), and they must become the atom keys `Config.Schema` expects. `kind`/`phase` use `String.to_existing_atom/1` (the atoms `:stage`, `:extract`, etc. are referenced in `@kinds`/`@phases`, so they exist at compile time) to reject typos cleanly.

- [ ] **Step 5: Run test to verify it passes**

Run: `mix test test/cham/plugin/manifest_test.exs`
Expected: PASS (7 tests).

- [ ] **Step 6: Commit**

```bash
git add lib/cham/plugin/manifest.ex test/cham/plugin/manifest_test.exs test/support/plugin_fixtures/extract_article/manifest.toml
git commit -m "feat(v3): add Cham.Plugin.Manifest TOML parse + structural validation"
```

## Task 2: ArtifactType vocabulary + validation

**Files:**
- Create: `lib/cham/plugin/artifact_type.ex`
- Test: `test/cham/plugin/artifact_type_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Cham.Plugin.ArtifactTypeTest do
  use ExUnit.Case, async: true
  alias Cham.Plugin.ArtifactType

  test "default seeded vocabulary includes the core types" do
    seeded = ArtifactType.default_seeded()
    assert "html_capture" in seeded
    assert "article_markdown" in seeded
    assert "thumbnail" in seeded
  end

  test "build/2 unions seeded types with declared types" do
    vocab = ArtifactType.build(["html_capture"], [["article_markdown"], ["audio", "html_capture"]])
    assert ArtifactType.known?(vocab, "html_capture")
    assert ArtifactType.known?(vocab, "article_markdown")
    assert ArtifactType.known?(vocab, "audio")
    refute ArtifactType.known?(vocab, "nope")
  end

  test "validate_types/2 returns :ok when all types are known" do
    vocab = ArtifactType.build(["html_capture", "article_markdown"], [])
    assert :ok == ArtifactType.validate_types(["html_capture", "article_markdown"], vocab)
  end

  test "validate_types/2 reports the first unknown type" do
    vocab = ArtifactType.build(["html_capture"], [])
    assert {:error, msg} = ArtifactType.validate_types(["html_capture", "ghost"], vocab)
    assert msg =~ "unknown artifact type: \"ghost\""
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/cham/plugin/artifact_type_test.exs`
Expected: FAIL — `Cham.Plugin.ArtifactType` is undefined.

- [ ] **Step 3: Implement the module**

```elixir
defmodule Cham.Plugin.ArtifactType do
  @moduledoc """
  The validated artifact-type vocabulary. A type is a first-class routing key
  that rides in `artifacts.labels["type"]` (no Phase 0 schema change). The
  vocabulary is a seeded set (config-extensible) unioned with every plugin's
  `declares_types`.
  """

  @default_seeded ~w(html_capture article_markdown audio thumbnail summary tags)

  @type vocabulary :: MapSet.t(String.t())

  @doc "The built-in seeded artifact types (config may extend this; see the registry)."
  @spec default_seeded() :: [String.t()]
  def default_seeded, do: @default_seeded

  @doc "Build the full vocabulary from a seeded list plus a list of `declares_types` lists."
  @spec build([String.t()], [[String.t()]]) :: vocabulary()
  def build(seeded, declared_lists) do
    declared = List.flatten(declared_lists)
    MapSet.new(seeded ++ declared)
  end

  @doc "Whether `type` is in the vocabulary."
  @spec known?(vocabulary(), String.t()) :: boolean()
  def known?(vocab, type), do: MapSet.member?(vocab, type)

  @doc "Validate a list of type names against the vocabulary. Reports the first unknown."
  @spec validate_types([String.t()], vocabulary()) :: :ok | {:error, String.t()}
  def validate_types(types, vocab) do
    case Enum.find(types, fn t -> not known?(vocab, t) end) do
      nil -> :ok
      bad -> {:error, "unknown artifact type: #{inspect(bad)}"}
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/cham/plugin/artifact_type_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/cham/plugin/artifact_type.ex test/cham/plugin/artifact_type_test.exs
git commit -m "feat(v3): add Cham.Plugin.ArtifactType vocabulary + validation"
```

---

## Task 3: WireProtocol structs + encode/decode

**Files:**
- Create: `lib/cham/plugin/wire_protocol.ex`
- Test: `test/cham/plugin/wire_protocol_test.exs`

This task defines the request/result structs, encodes requests to the JSON-ready map written into `request.json`, decodes `output.json` results, and implements the `waiting_for_input → failed(:unsupported)` mapping (§5.4).

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Cham.Plugin.WireProtocolTest do
  use ExUnit.Case, async: true
  alias Cham.Plugin.WireProtocol
  alias Cham.Plugin.WireProtocol.{PerformRequest, CanProcessRequest, SubscriptionRequest,
                                   Input, StageResult, SubscriptionResult}

  describe "encode_request/1" do
    test "encodes a stage perform request" do
      req = %PerformRequest{
        item_id: "item-1",
        config: %{"min_words" => 20},
        inputs: [%Input{type: "html_capture", labels: %{"origin" => "original"},
                        filenames: ["page.html"], input_path: "inputs"}]
      }

      assert %{
               "request" => "perform",
               "item_id" => "item-1",
               "config" => %{"min_words" => 20},
               "inputs" => [%{"type" => "html_capture", "labels" => %{"origin" => "original"},
                              "filenames" => ["page.html"], "input_path" => "inputs"}]
             } = WireProtocol.encode_request(req)
    end

    test "encodes a can_process request (no config)" do
      req = %CanProcessRequest{item_id: "item-1", inputs: []}
      assert %{"request" => "can_process", "item_id" => "item-1", "inputs" => []} =
               WireProtocol.encode_request(req)
    end

    test "encodes a subscription request with a null checkpoint" do
      req = %SubscriptionRequest{subscription_id: "sub-1", config: %{}, checkpoint: nil}
      encoded = WireProtocol.encode_request(req)
      assert encoded["request"] == "perform"
      assert encoded["subscription_id"] == "sub-1"
      assert encoded["checkpoint"] == nil
    end
  end

  describe "decode_stage_result/1" do
    test "decodes a produced result" do
      json = %{
        "outcome" => "produced",
        "artifacts" => [%{"type" => "article_markdown", "labels" => %{"format" => "text"},
                          "filenames" => ["content.md"]}],
        "item_metadata" => %{"title" => "Hi"},
        "provenance" => %{"tool" => "readability"}
      }

      assert {:ok, %StageResult{outcome: :produced} = r} = WireProtocol.decode_stage_result(json)
      assert [%{type: "article_markdown", labels: %{"format" => "text"}, filenames: ["content.md"]}] =
               r.artifacts
      assert r.item_metadata == %{"title" => "Hi"}
      assert r.provenance == %{"tool" => "readability"}
    end

    test "decodes not_applicable" do
      assert {:ok, %StageResult{outcome: :not_applicable}} =
               WireProtocol.decode_stage_result(%{"outcome" => "not_applicable"})
    end

    test "decodes a plugin-reported failure with a category" do
      assert {:ok, %StageResult{outcome: :failed, category: :blocked}} =
               WireProtocol.decode_stage_result(%{"outcome" => "failed", "category" => "blocked"})
    end

    test "maps waiting_for_input to failed(:unsupported)" do
      assert {:ok, %StageResult{outcome: :failed, category: :unsupported}} =
               WireProtocol.decode_stage_result(%{"outcome" => "waiting_for_input"})
    end

    test "rejects an unknown failure category" do
      assert {:error, _} =
               WireProtocol.decode_stage_result(%{"outcome" => "failed", "category" => "weird"})
    end

    test "rejects an unknown outcome" do
      assert {:error, _} = WireProtocol.decode_stage_result(%{"outcome" => "exploded"})
    end
  end

  describe "decode_probe/1" do
    test "decodes applicable true/false" do
      assert {:ok, true} = WireProtocol.decode_probe(%{"applicable" => true})
      assert {:ok, false} = WireProtocol.decode_probe(%{"applicable" => false})
    end

    test "rejects a non-boolean applicable" do
      assert {:error, _} = WireProtocol.decode_probe(%{"applicable" => "yes"})
    end
  end

  describe "decode_subscription_result/1" do
    test "decodes items and an opaque checkpoint" do
      json = %{
        "items" => [%{"url" => "https://x", "metadata" => %{"title" => "T"}}],
        "checkpoint" => "cursor-42"
      }

      assert {:ok, %SubscriptionResult{items: items, checkpoint: "cursor-42"}} =
               WireProtocol.decode_subscription_result(json)
      assert [%{"url" => "https://x"}] = items
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/cham/plugin/wire_protocol_test.exs`
Expected: FAIL — `Cham.Plugin.WireProtocol` is undefined.

- [ ] **Step 3: Implement the module**

```elixir
defmodule Cham.Plugin.WireProtocol do
  @moduledoc """
  The canonical request/result contract shared by both transports.

  Requests are encoded to a JSON-ready map (written to `request.json` for the
  subprocess transport; passed as a struct to the in-process transport).
  Results are decoded from the parsed `output.json` map (or the struct an
  in-process plugin returns). `working_dir` is the invocation's *argument*, not a
  wire field, so it never appears in the encoded request.
  """

  @failure_categories [:blocked, :unsupported, :bad_input, :error]

  defmodule Input do
    @moduledoc "One input artifact reference handed to a stage."
    @enforce_keys [:type]
    defstruct [:type, :input_path, labels: %{}, filenames: []]
  end

  defmodule PerformRequest do
    @moduledoc "Stage `perform` request."
    @enforce_keys [:item_id]
    defstruct [:item_id, config: %{}, inputs: []]
  end

  defmodule CanProcessRequest do
    @moduledoc "Stage `can_process` probe request."
    @enforce_keys [:item_id]
    defstruct [:item_id, inputs: []]
  end

  defmodule SubscriptionRequest do
    @moduledoc "Subscription `perform` request carrying the opaque checkpoint."
    @enforce_keys [:subscription_id]
    defstruct [:subscription_id, config: %{}, checkpoint: nil]
  end

  defmodule StageResult do
    @moduledoc "Decoded terminal result of a stage `perform`."
    @enforce_keys [:outcome]
    defstruct [:outcome, :category, artifacts: [], item_metadata: %{}, provenance: %{}]
  end

  defmodule SubscriptionResult do
    @moduledoc "Decoded result of a subscription `perform`."
    @enforce_keys [:items, :checkpoint]
    defstruct [:items, :checkpoint]
  end

  @doc "Known closed set of plugin-reportable failure categories."
  def failure_categories, do: @failure_categories

  @doc "Encode a request struct to a JSON-ready (string-keyed) map for `request.json`."
  def encode_request(%PerformRequest{} = r) do
    %{
      "request" => "perform",
      "item_id" => r.item_id,
      "config" => r.config,
      "inputs" => Enum.map(r.inputs, &encode_input/1)
    }
  end

  def encode_request(%CanProcessRequest{} = r) do
    %{
      "request" => "can_process",
      "item_id" => r.item_id,
      "inputs" => Enum.map(r.inputs, &encode_input/1)
    }
  end

  def encode_request(%SubscriptionRequest{} = r) do
    %{
      "request" => "perform",
      "subscription_id" => r.subscription_id,
      "config" => r.config,
      "checkpoint" => r.checkpoint
    }
  end

  defp encode_input(%Input{} = i) do
    %{
      "type" => i.type,
      "labels" => i.labels,
      "filenames" => i.filenames,
      "input_path" => i.input_path
    }
  end

  @doc """
  Decode a parsed `output.json` map into a `StageResult`. `waiting_for_input` is
  mapped to `failed(:unsupported)` (reserved outcome, spec §5.4).
  """
  @spec decode_stage_result(map()) :: {:ok, StageResult.t()} | {:error, String.t()}
  def decode_stage_result(%{"outcome" => "produced"} = json) do
    {:ok,
     %StageResult{
       outcome: :produced,
       artifacts: decode_artifacts(Map.get(json, "artifacts", [])),
       item_metadata: Map.get(json, "item_metadata", %{}),
       provenance: Map.get(json, "provenance", %{})
     }}
  end

  def decode_stage_result(%{"outcome" => "not_applicable"}),
    do: {:ok, %StageResult{outcome: :not_applicable}}

  def decode_stage_result(%{"outcome" => "waiting_for_input"}),
    do: {:ok, %StageResult{outcome: :failed, category: :unsupported}}

  def decode_stage_result(%{"outcome" => "failed", "category" => category}) do
    case category_atom(category) do
      {:ok, atom} -> {:ok, %StageResult{outcome: :failed, category: atom}}
      :error -> {:error, "unknown failure category: #{inspect(category)}"}
    end
  end

  def decode_stage_result(%{"outcome" => other}),
    do: {:error, "unknown outcome: #{inspect(other)}"}

  def decode_stage_result(_), do: {:error, "missing outcome"}

  @doc "Decode a `can_process` probe result."
  @spec decode_probe(map()) :: {:ok, boolean()} | {:error, String.t()}
  def decode_probe(%{"applicable" => v}) when is_boolean(v), do: {:ok, v}
  def decode_probe(other), do: {:error, "invalid probe result: #{inspect(other)}"}

  @doc "Decode a subscription `perform` result. The checkpoint is kept opaque."
  @spec decode_subscription_result(map()) :: {:ok, SubscriptionResult.t()} | {:error, String.t()}
  def decode_subscription_result(%{"items" => items} = json) when is_list(items),
    do: {:ok, %SubscriptionResult{items: items, checkpoint: Map.get(json, "checkpoint")}}

  def decode_subscription_result(other),
    do: {:error, "invalid subscription result: #{inspect(other)}"}

  defp decode_artifacts(list) do
    Enum.map(list, fn a ->
      %{
        type: Map.get(a, "type"),
        labels: Map.get(a, "labels", %{}),
        filenames: Map.get(a, "filenames", [])
      }
    end)
  end

  defp category_atom(str) do
    Enum.find(@failure_categories, fn c -> Atom.to_string(c) == str end)
    |> case do
      nil -> :error
      atom -> {:ok, atom}
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/cham/plugin/wire_protocol_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/cham/plugin/wire_protocol.ex test/cham/plugin/wire_protocol_test.exs
git commit -m "feat(v3): add Cham.Plugin.WireProtocol request/result structs + codec"
```

## Task 4: PluginEvent struct + in-process behaviours

**Files:**
- Create: `lib/cham/plugin/events.ex`
- Create: `lib/cham/plugin/stage.ex`
- Create: `lib/cham/plugin/subscription.ex`
- Test: `test/cham/plugin/events_test.exs`

The behaviours have no logic to unit-test directly; they are exercised through the transports (Tasks 5–6) and registry (Task 7). Only `Cham.Plugin.Events` gets a focused test (the struct + the topic helper).

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Cham.Plugin.EventsTest do
  use ExUnit.Case, async: true
  alias Cham.Plugin.Events
  alias Cham.Plugin.Events.PluginEvent

  test "builds a status event with a plugin/context and a topic" do
    ev = Events.new("extract_article", "item-1", :status, %{"message" => "Loading model"})
    assert %PluginEvent{plugin_id: "extract_article", context_id: "item-1", type: :status,
                        data: %{"message" => "Loading model"}} = ev
    assert Events.topic(ev) == "plugin:extract_article"
  end

  test "from_line/3 parses a JSONL status line into a typed event" do
    assert {:ok, %PluginEvent{type: :status, data: %{"message" => "hi"}}} =
             Events.from_line(~s({"event":"status","message":"hi"}), "p", "c")
  end

  test "from_line/3 parses progress and log events" do
    assert {:ok, %PluginEvent{type: :progress, data: %{"value" => 80}}} =
             Events.from_line(~s({"event":"progress","value":80}), "p", "c")

    assert {:ok, %PluginEvent{type: :log, data: %{"level" => "warn"}}} =
             Events.from_line(~s({"event":"log","level":"warn","message":"x"}), "p", "c")
  end

  test "from_line/3 ignores non-JSON or eventless lines" do
    assert :ignore = Events.from_line("not json", "p", "c")
    assert :ignore = Events.from_line(~s({"no":"event"}), "p", "c")
    assert :ignore = Events.from_line(~s({"event":"mystery"}), "p", "c")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/cham/plugin/events_test.exs`
Expected: FAIL — `Cham.Plugin.Events` is undefined.

- [ ] **Step 3: Implement `Cham.Plugin.Events`**

```elixir
defmodule Cham.Plugin.Events do
  @moduledoc """
  Progress events forwarded from a running plugin to the `Cham.EventBus`. These
  are *not* the result (that comes from `output.json` / the returned struct);
  they mirror v2's `ScriptOutput` live-progress forwarding.
  """

  @event_types %{"status" => :status, "progress" => :progress, "log" => :log}

  defmodule PluginEvent do
    @moduledoc "A single forwarded progress event."
    @enforce_keys [:plugin_id, :type, :data]
    defstruct [:plugin_id, :context_id, :type, :data]
  end

  @doc "Build a `PluginEvent`. `context_id` is the item_id/subscription_id (may be nil)."
  def new(plugin_id, context_id, type, data) when type in [:status, :progress, :log] do
    %PluginEvent{plugin_id: plugin_id, context_id: context_id, type: type, data: data}
  end

  @doc "The EventBus topic for a plugin's events (fans out to the coarse `plugin` topic)."
  def topic(%PluginEvent{plugin_id: id}), do: "plugin:#{id}"

  @doc """
  Parse one stdout JSONL line into a `PluginEvent`. Returns `:ignore` for
  non-JSON lines, lines without a known `"event"`, or unknown event types
  (stdout progress is optional and best-effort; only `output.json` is authoritative).
  """
  @spec from_line(String.t(), String.t(), String.t() | nil) :: {:ok, PluginEvent.t()} | :ignore
  def from_line(line, plugin_id, context_id) do
    with {:ok, %{"event" => event} = map} <- Jason.decode(line),
         type when not is_nil(type) <- Map.get(@event_types, event) do
      {:ok, new(plugin_id, context_id, type, Map.delete(map, "event"))}
    else
      _ -> :ignore
    end
  end
end
```

- [ ] **Step 4: Implement the two behaviours**

`lib/cham/plugin/stage.ex`:

```elixir
defmodule Cham.Plugin.Stage do
  @moduledoc """
  Behaviour for an in-process (Elixir) stage plugin. The in-process equivalent
  of a subprocess plugin's `manifest.toml` + entrypoints. `manifest/0` must
  return a `Cham.Plugin.Manifest` with `class: :in_process`; the registry stamps
  `source: {:module, __MODULE__}`.

  `perform/2` receives the request struct and an `emit` function (forwarding
  `status`/`progress`/`log` maps to the EventBus) and returns a
  `Cham.Plugin.WireProtocol.StageResult` — the in-process equivalent of writing
  `output.json`. Optional `can_process/1` returns a boolean.
  """
  alias Cham.Plugin.{Manifest, WireProtocol}

  @callback manifest() :: Manifest.t()
  @callback perform(WireProtocol.PerformRequest.t(), emit :: (map() -> :ok)) ::
              WireProtocol.StageResult.t()
  @callback can_process(WireProtocol.CanProcessRequest.t()) :: boolean()

  @optional_callbacks [can_process: 1]
end
```

`lib/cham/plugin/subscription.ex`:

```elixir
defmodule Cham.Plugin.Subscription do
  @moduledoc """
  Behaviour for an in-process subscription plugin. `perform/2` is handed the
  opaque checkpoint inside the request and returns a
  `Cham.Plugin.WireProtocol.SubscriptionResult` ({items, new checkpoint}).
  """
  alias Cham.Plugin.{Manifest, WireProtocol}

  @callback manifest() :: Manifest.t()
  @callback perform(WireProtocol.SubscriptionRequest.t(), emit :: (map() -> :ok)) ::
              WireProtocol.SubscriptionResult.t()
end
```

- [ ] **Step 5: Run test to verify it passes**

Run: `mix test test/cham/plugin/events_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/cham/plugin/events.ex lib/cham/plugin/stage.ex lib/cham/plugin/subscription.ex test/cham/plugin/events_test.exs
git commit -m "feat(v3): add Cham.Plugin.Events + Stage/Subscription behaviours"
```

---

## Task 5: InProcess transport

**Files:**
- Create: `lib/cham/plugin/transport/in_process.ex`
- Test: `test/cham/plugin/transport/in_process_test.exs`
- Test support: `test/support/plugin_fixtures/fake_stage.ex`

The in-process transport invokes the behaviour module directly: it builds an `emit` closure that publishes `PluginEvent`s to the EventBus, calls the module, and returns the result struct unchanged. No serialization, no files.

- [ ] **Step 1: Write the fake in-process stage (test support)**

Create `test/support/plugin_fixtures/fake_stage.ex`:

```elixir
defmodule Cham.PluginFixtures.FakeStage do
  @moduledoc false
  @behaviour Cham.Plugin.Stage
  alias Cham.Plugin.{Manifest, WireProtocol}

  @impl true
  def manifest do
    %Manifest{
      id: "fake_stage",
      kind: :stage,
      phase: :extract,
      version: 1,
      inputs: [%{type: "html_capture", labels: %{}}],
      outputs: [%{type: "article_markdown", labels: %{}}],
      declares_types: ["article_markdown"],
      class: :in_process,
      source: {:module, __MODULE__}
    }
  end

  @impl true
  def perform(%WireProtocol.PerformRequest{item_id: item_id}, emit) do
    emit.(%{event: "status", message: "working on #{item_id}"})

    %WireProtocol.StageResult{
      outcome: :produced,
      artifacts: [%{type: "article_markdown", labels: %{}, filenames: ["content.md"]}],
      item_metadata: %{"title" => "Faked"},
      provenance: %{"tool" => "fake"}
    }
  end

  @impl true
  def can_process(%WireProtocol.CanProcessRequest{inputs: inputs}), do: inputs != []
end
```

Note: this file lives under `test/support/`, which is on the `:test` elixirc path (`mix.exs` `elixirc_paths(:test)`), so it compiles only for tests. `emit` is called with atom-keyed maps; the transport normalizes to string keys (Step 3).

- [ ] **Step 2: Write the failing test**

```elixir
defmodule Cham.Plugin.Transport.InProcessTest do
  use ExUnit.Case, async: true
  alias Cham.Plugin.Transport.InProcess
  alias Cham.Plugin.WireProtocol.{PerformRequest, CanProcessRequest, StageResult}
  alias Cham.Plugin.Events.PluginEvent
  alias Cham.PluginFixtures.FakeStage

  test "perform returns the module's result struct and forwards emit events" do
    Cham.EventBus.subscribe("plugin:fake_stage")
    req = %PerformRequest{item_id: "item-9", inputs: []}

    assert %StageResult{outcome: :produced, item_metadata: %{"title" => "Faked"}} =
             InProcess.invoke(FakeStage, req, "item-9")

    assert_receive %PluginEvent{type: :status, data: %{"message" => "working on item-9"}}
  end

  test "can_process delegates to the module's optional callback" do
    req = %CanProcessRequest{item_id: "i", inputs: [%{type: "html_capture"}]}
    assert {:ok, true} = InProcess.can_process(FakeStage, req, "i")

    empty = %CanProcessRequest{item_id: "i", inputs: []}
    assert {:ok, false} = InProcess.can_process(FakeStage, empty, "i")
  end
end
```

- [ ] **Step 3: Implement the transport**

```elixir
defmodule Cham.Plugin.Transport.InProcess do
  @moduledoc """
  The in-process (fast-path) transport. Invokes an Elixir behaviour module
  directly: builds an `emit` closure that publishes `PluginEvent`s to the
  EventBus, calls the module, and returns the result struct verbatim. No
  serialization, no port, no files.
  """
  alias Cham.Plugin.Events
  alias Cham.Plugin.WireProtocol.{PerformRequest, CanProcessRequest, SubscriptionRequest}

  @doc "Invoke `perform/2` on `module` with `request`; returns the result struct."
  def invoke(module, %struct{} = request, context_id)
      when struct in [PerformRequest, SubscriptionRequest] do
    emit = build_emit(module_id(module), context_id)
    module.perform(request, emit)
  end

  @doc "Invoke the optional `can_process/1`; `{:ok, boolean}` or `{:error, :no_probe}`."
  def can_process(module, %CanProcessRequest{} = request, _context_id) do
    if function_exported?(module, :can_process, 1) do
      {:ok, module.can_process(request)}
    else
      {:error, :no_probe}
    end
  end

  defp build_emit(plugin_id, context_id) do
    fn raw ->
      data = normalize(raw)

      with %{"event" => event} <- data,
           type when not is_nil(type) <- event_type(event) do
        ev = Events.new(plugin_id, context_id, type, Map.delete(data, "event"))
        Cham.EventBus.publish(Events.topic(ev), ev)
      else
        _ -> :ok
      end

      :ok
    end
  end

  defp event_type("status"), do: :status
  defp event_type("progress"), do: :progress
  defp event_type("log"), do: :log
  defp event_type(_), do: nil

  defp normalize(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp module_id(module), do: module.manifest().id
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/cham/plugin/transport/in_process_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/cham/plugin/transport/in_process.ex test/cham/plugin/transport/in_process_test.exs test/support/plugin_fixtures/fake_stage.ex
git commit -m "feat(v3): add Cham.Plugin.Transport.InProcess fast-path transport"
```

## Task 6: Subprocess transport

**Files:**
- Create: `lib/cham/plugin/transport/subprocess.ex`
- Test: `test/cham/plugin/transport/subprocess_test.exs`
- Fixtures: `test/support/plugin_fixtures/echo_stage/{manifest.toml,perform.sh,check.sh}`, `test/support/plugin_fixtures/crash_stage/perform.sh`, `test/support/plugin_fixtures/slow_stage/perform.sh`

This transport is the **single port-spawning path** in the v3 tree (the v2 `ScriptRunner` was removed in Task 0). The wire protocol needs stdout = line-delimited JSONL events and stderr = raw logs to a file — which a plain merged-stream port (`:stderr_to_stdout`) can't provide — so it opens a `Port` with `{:line, N}` (line-buffered stdout) and a `sh -c` wrapper that redirects stderr to the log file. It writes `request.json` (atomic), deletes any stale `output.json`, spawns the entrypoint with `working_dir` as its sole argument, forwards JSONL events to the EventBus, and after exit reads `output.json` (absent/garbage → `failed(:error)`; timeout → kill → `failed(:error)`).

- [ ] **Step 1: Write the fixtures**

`test/support/plugin_fixtures/echo_stage/manifest.toml`:

```toml
id = "echo_stage"
kind = "stage"
phase = "extract"
version = 1
inputs  = [ { type = "html_capture" } ]
outputs = [ { type = "article_markdown" } ]
declares_types = ["article_markdown"]

[entrypoints]
perform = "sh perform.sh"
can_process = "sh check.sh"
```

`test/support/plugin_fixtures/echo_stage/perform.sh`:

```sh
#!/bin/sh
WD="$1"
test -f "$WD/request.json" || { echo "missing request.json" 1>&2; exit 2; }
echo '{"event":"status","message":"starting"}'
echo '{"event":"progress","value":50}'
echo "a raw stderr log line" 1>&2
cat > "$WD/output.json.tmp" <<'JSON'
{"outcome":"produced","artifacts":[{"type":"article_markdown","labels":{},"filenames":["content.md"]}],"item_metadata":{"title":"Echo"},"provenance":{"tool":"echo"}}
JSON
mv "$WD/output.json.tmp" "$WD/output.json"
```

`test/support/plugin_fixtures/echo_stage/check.sh`:

```sh
#!/bin/sh
WD="$1"
echo '{"applicable":true}' > "$WD/output.json"
```

`test/support/plugin_fixtures/crash_stage/perform.sh`:

```sh
#!/bin/sh
echo "boom" 1>&2
exit 1
```

`test/support/plugin_fixtures/slow_stage/perform.sh`:

```sh
#!/bin/sh
sleep 10
```

- [ ] **Step 2: Write the failing test**

```elixir
defmodule Cham.Plugin.Transport.SubprocessTest do
  use ExUnit.Case, async: true
  alias Cham.Plugin.Transport.Subprocess
  alias Cham.Plugin.{Manifest, WireProtocol}
  alias Cham.Plugin.WireProtocol.{PerformRequest, CanProcessRequest, StageResult}
  alias Cham.Plugin.Events.PluginEvent

  @fixtures "test/support/plugin_fixtures"

  defp manifest(dir, entrypoints) do
    %Manifest{
      id: Path.basename(dir),
      kind: :stage,
      phase: :extract,
      version: 1,
      entrypoints: entrypoints,
      class: :subprocess,
      source: {:dir, Path.expand(Path.join(@fixtures, dir))}
    }
  end

  @tag :tmp_dir
  test "perform reads request.json, forwards JSONL events, parses output.json", %{tmp_dir: wd} do
    m = manifest("echo_stage", %{perform: "sh perform.sh", can_process: "sh check.sh"})
    Cham.EventBus.subscribe("plugin:echo_stage")
    req = %PerformRequest{item_id: "item-1", inputs: []}

    assert %StageResult{outcome: :produced, item_metadata: %{"title" => "Echo"}} =
             Subprocess.invoke(m, req, wd, timeout: 10_000)

    assert File.read!(Path.join(wd, "request.json")) =~ ~s("item_id")
    assert_receive %PluginEvent{type: :status, data: %{"message" => "starting"}}
    assert_receive %PluginEvent{type: :progress, data: %{"value" => 50}}
  end

  @tag :tmp_dir
  test "stderr is captured to the log file", %{tmp_dir: wd} do
    m = manifest("echo_stage", %{perform: "sh perform.sh", can_process: nil})
    log = Path.join(wd, "stage.log")
    req = %PerformRequest{item_id: "i", inputs: []}

    Subprocess.invoke(m, req, wd, timeout: 10_000, log_to: log)
    assert File.read!(log) =~ "a raw stderr log line"
  end

  @tag :tmp_dir
  test "a stale output.json from a previous run is deleted before invoking", %{tmp_dir: wd} do
    File.write!(Path.join(wd, "output.json"), ~s({"outcome":"not_applicable"}))
    m = manifest("echo_stage", %{perform: "sh perform.sh", can_process: nil})
    req = %PerformRequest{item_id: "i", inputs: []}

    assert %StageResult{outcome: :produced} = Subprocess.invoke(m, req, wd, timeout: 10_000)
  end

  @tag :tmp_dir
  test "missing output.json (crash) maps to failed(:error)", %{tmp_dir: wd} do
    m = manifest("crash_stage", %{perform: "sh perform.sh", can_process: nil})
    req = %PerformRequest{item_id: "i", inputs: []}

    assert %StageResult{outcome: :failed, category: :error} =
             Subprocess.invoke(m, req, wd, timeout: 10_000)
  end

  @tag :tmp_dir
  test "garbage output.json maps to failed(:error)", %{tmp_dir: wd} do
    File.write!(Path.join(wd, "perform_marker"), "")
    m = manifest("echo_stage", %{perform: "sh -c 'printf nonsense > \"$1/output.json\"' --", can_process: nil})
    req = %PerformRequest{item_id: "i", inputs: []}

    assert %StageResult{outcome: :failed, category: :error} =
             Subprocess.invoke(m, req, wd, timeout: 10_000)
  end

  @tag :tmp_dir
  test "timeout kills the process and maps to failed(:error)", %{tmp_dir: wd} do
    m = manifest("slow_stage", %{perform: "sh perform.sh", can_process: nil})
    req = %PerformRequest{item_id: "i", inputs: []}

    assert %StageResult{outcome: :failed, category: :error} =
             Subprocess.invoke(m, req, wd, timeout: 300)
  end

  @tag :tmp_dir
  test "can_process probe returns {:ok, boolean}", %{tmp_dir: wd} do
    m = manifest("echo_stage", %{perform: "sh perform.sh", can_process: "sh check.sh"})
    req = %CanProcessRequest{item_id: "i", inputs: []}

    assert {:ok, true} = Subprocess.invoke(m, req, wd, timeout: 10_000)
  end
end
```

- [ ] **Step 3: Implement the transport**

```elixir
defmodule Cham.Plugin.Transport.Subprocess do
  @moduledoc """
  The external-subprocess transport. One-shot per invocation: writes
  `request.json` into `working_dir`, deletes any stale `output.json`, spawns the
  entrypoint with `working_dir` as its sole argument (cwd = the plugin dir),
  line-buffers stdout as JSONL progress events (forwarded to the EventBus),
  redirects stderr to a log file, and after the process exits reads
  `output.json`. Absent/unparseable `output.json` or a timeout maps to
  `failed(:error)` (catches crash/OOM/hang).
  """
  require Logger
  alias Cham.Archive.Layout
  alias Cham.Plugin.{Events, WireProtocol}
  alias Cham.Plugin.WireProtocol.{PerformRequest, CanProcessRequest, SubscriptionRequest}

  @default_timeout 300_000

  @doc """
  Invoke a subprocess plugin. The request struct determines the entrypoint
  (`perform` vs `can_process`) and how `output.json` is decoded. Options:
  `:timeout` (ms, default 5 min) and `:log_to` (stderr log path, default
  `working_dir/stage.log`).
  """
  def invoke(manifest, request, working_dir, opts \\ []) do
    working_dir = Path.expand(working_dir)
    File.mkdir_p!(working_dir)
    output_path = Path.join(working_dir, "output.json")
    File.rm(output_path)

    :ok =
      Layout.atomic_write(
        Path.join(working_dir, "request.json"),
        Jason.encode!(WireProtocol.encode_request(request))
      )

    entrypoint = entrypoint_for(request, manifest)
    log_path = Path.expand(Keyword.get(opts, :log_to, Path.join(working_dir, "stage.log")))
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    {:dir, plugin_dir} = manifest.source

    exit_status =
      run_port(entrypoint, working_dir, plugin_dir, log_path, timeout, manifest.id, context_id(request))

    decode_result(request, output_path, exit_status)
  end

  defp entrypoint_for(%CanProcessRequest{}, manifest), do: manifest.entrypoints.can_process
  defp entrypoint_for(_perform, manifest), do: manifest.entrypoints.perform

  defp context_id(%PerformRequest{item_id: id}), do: id
  defp context_id(%CanProcessRequest{item_id: id}), do: id
  defp context_id(%SubscriptionRequest{subscription_id: id}), do: id

  # Spawn `sh -c 'exec <entrypoint> "$1" 2> "$2"' sh <working_dir> <log_path>`,
  # line-buffering stdout. The entrypoint string comes from the trusted on-disk
  # manifest (operator-authored), not remote input.
  defp run_port(entrypoint, working_dir, plugin_dir, log_path, timeout, plugin_id, context_id) do
    sh = System.find_executable("sh")
    script = "exec #{entrypoint} \"$1\" 2> \"$2\""

    File.mkdir_p!(Path.dirname(log_path))

    port =
      Port.open(
        {:spawn_executable, sh},
        [
          :binary,
          :exit_status,
          {:line, 65_536},
          cd: plugin_dir,
          args: ["-c", script, "sh", working_dir, log_path]
        ]
      )

    collect(port, timeout, plugin_id, context_id, "")
  end

  defp collect(port, timeout, plugin_id, context_id, buffer) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        forward(buffer <> chunk, plugin_id, context_id)
        collect(port, timeout, plugin_id, context_id, "")

      {^port, {:data, {:noeol, chunk}}} ->
        collect(port, timeout, plugin_id, context_id, buffer <> chunk)

      {^port, {:exit_status, status}} ->
        {:exited, status}
    after
      timeout ->
        kill_port(port)
        :timeout
    end
  end

  defp forward(line, plugin_id, context_id) do
    case Events.from_line(line, plugin_id, context_id) do
      {:ok, event} -> Cham.EventBus.publish(Events.topic(event), event)
      :ignore -> :ok
    end
  end

  defp kill_port(port) do
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    Port.close(port)
    System.cmd("kill", ["-9", "#{os_pid}"])
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp decode_result(%CanProcessRequest{}, output_path, status) do
    with {:exited, _} <- status,
         {:ok, body} <- File.read(output_path),
         {:ok, json} <- Jason.decode(body),
         {:ok, applicable} <- WireProtocol.decode_probe(json) do
      {:ok, applicable}
    else
      _ -> {:error, :crashed}
    end
  end

  defp decode_result(%SubscriptionRequest{}, output_path, status) do
    with {:exited, _} <- status,
         {:ok, body} <- File.read(output_path),
         {:ok, json} <- Jason.decode(body),
         {:ok, result} <- WireProtocol.decode_subscription_result(json) do
      result
    else
      _ -> {:error, :crashed}
    end
  end

  defp decode_result(%PerformRequest{}, output_path, status) do
    with {:exited, _} <- status,
         {:ok, body} <- File.read(output_path),
         {:ok, json} <- Jason.decode(body),
         {:ok, result} <- WireProtocol.decode_stage_result(json) do
      result
    else
      other ->
        Logger.warning("subprocess perform produced no valid output.json (#{inspect(other)})")
        %WireProtocol.StageResult{outcome: :failed, category: :error}
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/cham/plugin/transport/subprocess_test.exs`
Expected: PASS (7 tests). The timeout test should take ~0.3s, not 10s (proves the kill works).

- [ ] **Step 5: Commit**

```bash
git add lib/cham/plugin/transport/subprocess.ex test/cham/plugin/transport/subprocess_test.exs test/support/plugin_fixtures/echo_stage test/support/plugin_fixtures/crash_stage test/support/plugin_fixtures/slow_stage
git commit -m "feat(v3): add Cham.Plugin.Transport.Subprocess one-shot wire transport"
```

## Task 7: Registry (discovery, validation, catalog, config registration)

**Files:**
- Create: `lib/cham/plugin/registry.ex`
- Test: `test/cham/plugin/registry_test.exs`
- Fixtures: `test/support/plugin_fixtures/malformed_stage/manifest.toml`, `test/support/plugin_fixtures/bad_types_stage/manifest.toml`

The registry is a GenServer holding a static catalog built once at init. The build logic is a **pure** function `discover/1` so it can be unit-tested without starting a process. It scans the plugins root, parses+validates each `manifest.toml` (malformed → logged + skipped), adds compile-time in-process modules, drops disabled ids, builds the artifact-type vocabulary (seeded ∪ all `declares_types`), validates each manifest's I/O types (unknown type → logged + skipped), and registers each kept plugin's `config_schema` into the `plugins.<id>` config namespace.

- [ ] **Step 1: Write the extra fixtures**

`test/support/plugin_fixtures/malformed_stage/manifest.toml`:

```toml
id = = =
```

`test/support/plugin_fixtures/bad_types_stage/manifest.toml`:

```toml
id = "bad_types_stage"
kind = "stage"
phase = "extract"
inputs = [ { type = "ghost" } ]

[entrypoints]
perform = "true"
```

- [ ] **Step 2: Write the failing test**

```elixir
defmodule Cham.Plugin.RegistryTest do
  use ExUnit.Case, async: true
  alias Cham.Plugin.{Registry, ArtifactType}
  alias Cham.PluginFixtures.FakeStage

  @root "test/support/plugin_fixtures"

  defp opts(extra) do
    parent = self()

    Keyword.merge(
      [
        plugins_root: @root,
        in_process_modules: [],
        seeded_types: ArtifactType.default_seeded(),
        disabled: [],
        config_register: fn ns, schema -> send(parent, {:config_registered, ns, schema}); :ok end
      ],
      extra
    )
  end

  describe "discover/1" do
    test "discovers valid subprocess manifests and skips malformed/unknown-type ones" do
      {catalog, _vocab} = Registry.discover(opts([]))
      ids = Map.keys(catalog)

      assert "echo_stage" in ids
      assert "extract_article" in ids
      refute "malformed_stage" in ids
      refute "bad_types_stage" in ids
    end

    test "includes compile-time in-process modules and stamps their source" do
      {catalog, _vocab} = Registry.discover(opts(in_process_modules: [FakeStage]))
      assert %{class: :in_process, source: {:module, FakeStage}} = catalog["fake_stage"]
    end

    test "drops disabled plugin ids" do
      {catalog, _vocab} = Registry.discover(opts(disabled: ["echo_stage"]))
      refute Map.has_key?(catalog, "echo_stage")
      assert Map.has_key?(catalog, "extract_article")
    end

    test "builds a vocabulary of seeded plus declared types" do
      {_catalog, vocab} = Registry.discover(opts([]))
      assert ArtifactType.known?(vocab, "html_capture")
      assert ArtifactType.known?(vocab, "article_markdown")
    end

    test "registers config schemas for plugins that declare them" do
      Registry.discover(opts([]))
      assert_receive {:config_registered, "plugins.extract_article", [%{key: :min_words}]}
    end
  end

  describe "GenServer API" do
    test "lookup and list reflect the discovered catalog" do
      start_supervised!(
        {Registry, opts(name: :test_registry, in_process_modules: [FakeStage])}
      )

      assert {:ok, %{id: "echo_stage"}} = Registry.lookup(:test_registry, "echo_stage")
      assert {:ok, %{id: "fake_stage", class: :in_process}} =
               Registry.lookup(:test_registry, "fake_stage")
      assert :error = Registry.lookup(:test_registry, "nope")
      assert "echo_stage" in Enum.map(Registry.list(:test_registry), & &1.id)
    end
  end
end
```

- [ ] **Step 3: Implement the registry**

```elixir
defmodule Cham.Plugin.Registry do
  @moduledoc """
  Discovers, validates, and catalogs plugins at startup. Scans the configured
  plugins root for `manifest.toml` directories, adds compile-time in-process
  behaviour modules, builds the artifact-type vocabulary, validates each
  plugin's typed I/O, registers per-plugin config schemas, and holds the static
  catalog (`id => manifest`). Malformed or unknown-type plugins are logged and
  skipped — never fatal to boot.
  """
  use GenServer
  require Logger
  alias Cham.Plugin.{ArtifactType, Manifest}

  # --- Public API ---

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Look up a manifest by id."
  @spec lookup(GenServer.server(), String.t()) :: {:ok, Manifest.t()} | :error
  def lookup(server \\ __MODULE__, id), do: GenServer.call(server, {:lookup, id})

  @doc "All catalogued manifests."
  @spec list(GenServer.server()) :: [Manifest.t()]
  def list(server \\ __MODULE__), do: GenServer.call(server, :list)

  @doc "The artifact-type vocabulary."
  @spec vocabulary(GenServer.server()) :: ArtifactType.vocabulary()
  def vocabulary(server \\ __MODULE__), do: GenServer.call(server, :vocabulary)

  # --- Pure discovery (unit-testable without a process) ---

  @doc """
  Build `{catalog, vocabulary}` from options:
  `:plugins_root`, `:in_process_modules`, `:seeded_types`, `:disabled`,
  `:config_register` (a `(namespace, schema -> any)` function).
  """
  def discover(opts) do
    seeded = Keyword.get(opts, :seeded_types, ArtifactType.default_seeded())
    disabled = Keyword.get(opts, :disabled, [])
    config_register = Keyword.get(opts, :config_register, &Cham.Config.Manager.register/2)

    manifests =
      (scan_subprocess(Keyword.get(opts, :plugins_root, "plugins")) ++
         load_in_process(Keyword.get(opts, :in_process_modules, [])))
      |> Enum.reject(&(&1.id in disabled))

    vocabulary = ArtifactType.build(seeded, Enum.map(manifests, & &1.declares_types))

    kept = Enum.filter(manifests, &valid_types?(&1, vocabulary))
    Enum.each(kept, &register_config(&1, config_register))

    catalog = Map.new(kept, &{&1.id, &1})
    {catalog, vocabulary}
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    {catalog, vocabulary} = discover(opts)
    {:ok, %{catalog: catalog, vocabulary: vocabulary}}
  end

  @impl true
  def handle_call({:lookup, id}, _from, state) do
    {:reply, Map.fetch(state.catalog, id), state}
  end

  def handle_call(:list, _from, state) do
    {:reply, Map.values(state.catalog), state}
  end

  def handle_call(:vocabulary, _from, state) do
    {:reply, state.vocabulary, state}
  end

  # --- Internals ---

  defp scan_subprocess(root) do
    case File.ls(root) do
      {:ok, entries} ->
        entries
        |> Enum.map(&Path.join([root, &1, "manifest.toml"]))
        |> Enum.filter(&File.regular?/1)
        |> Enum.flat_map(&parse_manifest/1)

      {:error, _} ->
        []
    end
  end

  defp parse_manifest(path) do
    case Manifest.parse(path) do
      {:ok, m} ->
        [m]

      {:error, reason} ->
        Logger.warning("skipping plugin manifest #{path}: #{reason}")
        []
    end
  end

  defp load_in_process(modules) do
    Enum.flat_map(modules, fn module ->
      manifest = %{module.manifest() | class: :in_process, source: {:module, module}}

      case Manifest.validate(manifest) do
        {:ok, m} ->
          [m]

        {:error, reason} ->
          Logger.warning("skipping in-process plugin #{inspect(module)}: #{reason}")
          []
      end
    end)
  end

  defp valid_types?(manifest, vocabulary) do
    types = Enum.map(manifest.inputs ++ manifest.outputs, & &1.type)

    case ArtifactType.validate_types(types, vocabulary) do
      :ok ->
        true

      {:error, reason} ->
        Logger.warning("skipping plugin #{manifest.id}: #{reason}")
        false
    end
  end

  defp register_config(%{config_schema: []}, _fun), do: :ok

  defp register_config(%{id: id, config_schema: schema}, fun) do
    fun.("plugins.#{id}", schema)
    :ok
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/cham/plugin/registry_test.exs`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/cham/plugin/registry.ex test/cham/plugin/registry_test.exs test/support/plugin_fixtures/malformed_stage test/support/plugin_fixtures/bad_types_stage
git commit -m "feat(v3): add Cham.Plugin.Registry discovery/validation/catalog"
```

## Task 8: Runtime (unified dispatch by class)

**Files:**
- Create: `lib/cham/plugin/runtime.ex`
- Test: `test/cham/plugin/runtime_test.exs`

The runtime is the single entry point callers use. It looks the plugin up in the registry and dispatches to the right transport purely on `class` — callers never know which. This is the seam Phase 4's executor calls.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Cham.Plugin.RuntimeTest do
  use ExUnit.Case, async: true
  alias Cham.Plugin.{Runtime, Registry, ArtifactType}
  alias Cham.Plugin.WireProtocol.{PerformRequest, CanProcessRequest, StageResult}
  alias Cham.PluginFixtures.FakeStage

  @root "test/support/plugin_fixtures"

  setup do
    start_supervised!(
      {Registry,
       name: :runtime_registry,
       plugins_root: @root,
       in_process_modules: [FakeStage],
       seeded_types: ArtifactType.default_seeded(),
       disabled: [],
       config_register: fn _ns, _schema -> :ok end}
    )

    :ok
  end

  @tag :tmp_dir
  test "dispatches an in-process stage perform", %{tmp_dir: wd} do
    req = %PerformRequest{item_id: "i", inputs: []}

    assert %StageResult{outcome: :produced, item_metadata: %{"title" => "Faked"}} =
             Runtime.run("fake_stage", req, wd, registry: :runtime_registry)
  end

  @tag :tmp_dir
  test "dispatches a subprocess stage perform", %{tmp_dir: wd} do
    req = %PerformRequest{item_id: "i", inputs: []}

    assert %StageResult{outcome: :produced, item_metadata: %{"title" => "Echo"}} =
             Runtime.run("echo_stage", req, wd, registry: :runtime_registry, timeout: 10_000)
  end

  @tag :tmp_dir
  test "dispatches a can_process probe (both classes)", %{tmp_dir: wd} do
    inproc = %CanProcessRequest{item_id: "i", inputs: [%{type: "html_capture"}]}
    assert {:ok, true} = Runtime.run("fake_stage", inproc, wd, registry: :runtime_registry)

    sub = %CanProcessRequest{item_id: "i", inputs: []}
    assert {:ok, true} = Runtime.run("echo_stage", sub, wd, registry: :runtime_registry, timeout: 10_000)
  end

  @tag :tmp_dir
  test "returns {:error, :unknown_plugin} for an unregistered id", %{tmp_dir: wd} do
    req = %PerformRequest{item_id: "i", inputs: []}
    assert {:error, :unknown_plugin} = Runtime.run("ghost", req, wd, registry: :runtime_registry)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/cham/plugin/runtime_test.exs`
Expected: FAIL — `Cham.Plugin.Runtime` is undefined.

- [ ] **Step 3: Implement the runtime**

```elixir
defmodule Cham.Plugin.Runtime do
  @moduledoc """
  The unified plugin-invocation entry point. Looks a plugin up in the registry
  and dispatches to the in-process or subprocess transport purely on the
  plugin's `class` — the caller (and, later, `plan`) never knows which. This is
  the seam Phase 4's executor invokes.
  """
  alias Cham.Plugin.Registry
  alias Cham.Plugin.Transport.{InProcess, Subprocess}
  alias Cham.Plugin.WireProtocol.{PerformRequest, CanProcessRequest, SubscriptionRequest}

  @doc """
  Invoke a plugin by id with a request struct. `working_dir` is the subprocess
  invocation's working directory (created if needed; ignored by the in-process
  transport). Options: `:registry` (server, default `Cham.Plugin.Registry`),
  `:timeout`, `:log_to` (subprocess only).
  """
  def run(plugin_id, request, working_dir, opts \\ []) do
    registry = Keyword.get(opts, :registry, Registry)

    case Registry.lookup(registry, plugin_id) do
      {:ok, manifest} -> dispatch(manifest, request, working_dir, opts)
      :error -> {:error, :unknown_plugin}
    end
  end

  defp dispatch(%{class: :in_process, source: {:module, module}}, request, _working_dir, _opts) do
    case request do
      %CanProcessRequest{} -> InProcess.can_process(module, request, context_id(request))
      _ -> InProcess.invoke(module, request, context_id(request))
    end
  end

  defp dispatch(%{class: :subprocess} = manifest, request, working_dir, opts) do
    Subprocess.invoke(manifest, request, working_dir, Keyword.take(opts, [:timeout, :log_to]))
  end

  defp context_id(%PerformRequest{item_id: id}), do: id
  defp context_id(%CanProcessRequest{item_id: id}), do: id
  defp context_id(%SubscriptionRequest{subscription_id: id}), do: id
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/cham/plugin/runtime_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/cham/plugin/runtime.ex test/cham/plugin/runtime_test.exs
git commit -m "feat(v3): add Cham.Plugin.Runtime unified class-based dispatch"
```

## Task 9: Layout `stage_path/2` + application wiring

**Files:**
- Modify: `lib/cham/archive/layout.ex` (add `stage_path/2`)
- Test: `test/cham/archive/layout_test.exs` (add one assertion)
- Modify: `lib/cham/plugin/registry.ex` (resolve runtime opts from config in `init/1`)
- Modify: `lib/cham/application.ex` (add the supervised Registry child)

- [ ] **Step 1: Add the failing Layout test**

Add to `test/cham/archive/layout_test.exs` (inside the existing test module):

```elixir
  test "stage_path builds stages/<stage_id>-<ts>" do
    assert Cham.Archive.Layout.stage_path("extract_article", "20260601T090705Z") ==
             "stages/extract_article-20260601T090705Z"
  end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mix test test/cham/archive/layout_test.exs`
Expected: FAIL — `stage_path/2` is undefined.

- [ ] **Step 3: Add `stage_path/2` to `Cham.Archive.Layout`**

Insert after `snapshot_path/1` (around line 57):

```elixir
  @doc "Relative stage working dir (under the item dir): `stages/<stage_id>-<ts>`."
  @spec stage_path(String.t(), String.t()) :: String.t()
  def stage_path(stage_id, ts) when is_binary(stage_id) and is_binary(ts),
    do: Path.join("stages", "#{stage_id}-#{ts}")
```

- [ ] **Step 4: Run it to verify it passes**

Run: `mix test test/cham/archive/layout_test.exs`
Expected: PASS.

- [ ] **Step 5: Teach the registry to resolve seeded/disabled/root from config**

In `lib/cham/plugin/registry.ex`, replace `init/1` and add private helpers. The app-instance reads the `plugins` config namespace (registering it on first use); test instances pass `:seeded_types` explicitly and bypass config entirely.

Replace:

```elixir
  @impl true
  def init(opts) do
    {catalog, vocabulary} = discover(opts)
    {:ok, %{catalog: catalog, vocabulary: vocabulary}}
  end
```

with:

```elixir
  @plugins_namespace "plugins"

  @impl true
  def init(opts) do
    {catalog, vocabulary} = discover(resolve_runtime_opts(opts))
    {:ok, %{catalog: catalog, vocabulary: vocabulary}}
  end

  # Tests pass :seeded_types explicitly and skip config entirely. The supervised
  # app instance reads the `plugins` namespace (registering it on first use).
  defp resolve_runtime_opts(opts) do
    if Keyword.has_key?(opts, :seeded_types) do
      opts
    else
      config = read_plugins_config()
      seeded = ArtifactType.default_seeded() ++ parse_list(Map.get(config, :seeded_artifact_types))

      opts
      |> Keyword.put_new(:plugins_root, Map.get(config, :plugins_root, "plugins"))
      |> Keyword.put(:seeded_types, seeded)
      |> Keyword.put(:disabled, parse_list(Map.get(config, :disabled)))
    end
  end

  defp read_plugins_config do
    _ =
      case Cham.Config.Manager.register(@plugins_namespace, plugins_config_schema()) do
        :ok -> :ok
        {:error, :already_registered} -> :ok
      end

    case Cham.Config.Manager.read_all(@plugins_namespace) do
      {:ok, map} -> map
      _ -> %{}
    end
  end

  defp plugins_config_schema do
    [
      %{
        key: :plugins_root,
        type: :string,
        default: "plugins",
        description: "Directory scanned for subprocess plugin manifests.",
        required: false,
        options: nil
      },
      %{
        key: :seeded_artifact_types,
        type: :string,
        default: "",
        description: "Comma-separated artifact types added to the seeded vocabulary.",
        required: false,
        options: nil
      },
      %{
        key: :disabled,
        type: :string,
        default: "",
        description: "Comma-separated plugin ids to parse but exclude from the catalog.",
        required: false,
        options: nil
      }
    ]
  end

  defp parse_list(nil), do: []
  defp parse_list(""), do: []
  defp parse_list(str), do: str |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
```

- [ ] **Step 6: Add the supervised Registry child**

In `lib/cham/application.ex`, add to the `children` list (after the `Cham.Config.Manager` child, before `Cham.Subscriptions.Supervisor`):

```elixir
      {Cham.Plugin.Registry, in_process_modules: []},
```

The `in_process_modules: []` is correct for Phase 1: no in-process plugins ship yet (the RSS subscription backend is re-homed as an in-process subscription plugin in Phase 4/5). Placement after `Cham.Config.Manager` guarantees config is readable during `Registry.init/1`.

- [ ] **Step 7: Run the focused suites + boot check**

Run: `mix test test/cham/plugin/ test/cham/archive/layout_test.exs`
Expected: PASS (all plugin + layout tests).

Run: `mix compile --warnings-as-errors`
Expected: clean compile (proves the supervision child + registry changes compile).

- [ ] **Step 8: Commit**

```bash
git add lib/cham/archive/layout.ex test/cham/archive/layout_test.exs lib/cham/plugin/registry.ex lib/cham/application.ex
git commit -m "feat(v3): wire Cham.Plugin.Registry into the supervision tree + plugins config namespace"
```

## Task 10: Subscription invocation contract (both classes)

**Files:**
- Create: `test/support/plugin_fixtures/fake_subscription.ex`
- Fixtures: `test/support/plugin_fixtures/sub_feed/{manifest.toml,perform.sh}`
- Test: `test/cham/plugin/subscription_contract_test.exs`

Phase 1 builds only the subscription *invocation contract* — the one-shot call and the opaque-checkpoint round-trip — testable end-to-end through the Runtime. The scheduler, checkpoint persistence, and submit wiring are Phase 4/5.

- [ ] **Step 1: Write the in-process fake subscription**

Create `test/support/plugin_fixtures/fake_subscription.ex`:

```elixir
defmodule Cham.PluginFixtures.FakeSubscription do
  @moduledoc false
  @behaviour Cham.Plugin.Subscription
  alias Cham.Plugin.{Manifest, WireProtocol}

  @impl true
  def manifest do
    %Manifest{
      id: "fake_subscription",
      kind: :subscription,
      class: :in_process,
      source: {:module, __MODULE__}
    }
  end

  @impl true
  def perform(%WireProtocol.SubscriptionRequest{checkpoint: checkpoint}, _emit) do
    case checkpoint do
      nil ->
        %WireProtocol.SubscriptionResult{
          items: [%{"url" => "https://x/1", "metadata" => %{}}],
          checkpoint: "v1"
        }

      other ->
        # Recognizes the checkpoint it issued and reports nothing new (round-trip).
        %WireProtocol.SubscriptionResult{items: [], checkpoint: other}
    end
  end
end
```

- [ ] **Step 2: Write the subprocess subscription fixture**

`test/support/plugin_fixtures/sub_feed/manifest.toml`:

```toml
id = "sub_feed"
kind = "subscription"
version = 1

[entrypoints]
perform = "sh perform.sh"
```

`test/support/plugin_fixtures/sub_feed/perform.sh`:

```sh
#!/bin/sh
WD="$1"
cat > "$WD/output.json.tmp" <<'JSON'
{"items":[{"url":"https://feed/1","metadata":{"title":"One"}}],"checkpoint":"etag-xyz"}
JSON
mv "$WD/output.json.tmp" "$WD/output.json"
```

- [ ] **Step 3: Write the failing test**

```elixir
defmodule Cham.Plugin.SubscriptionContractTest do
  use ExUnit.Case, async: true
  alias Cham.Plugin.{Runtime, Registry, ArtifactType}
  alias Cham.Plugin.WireProtocol.{SubscriptionRequest, SubscriptionResult}
  alias Cham.PluginFixtures.FakeSubscription

  @root "test/support/plugin_fixtures"

  setup do
    start_supervised!(
      {Registry,
       name: :sub_registry,
       plugins_root: @root,
       in_process_modules: [FakeSubscription],
       seeded_types: ArtifactType.default_seeded(),
       disabled: [],
       config_register: fn _ns, _schema -> :ok end}
    )

    :ok
  end

  @tag :tmp_dir
  test "in-process subscription round-trips the opaque checkpoint", %{tmp_dir: wd} do
    first = %SubscriptionRequest{subscription_id: "s", checkpoint: nil}

    assert %SubscriptionResult{items: [%{"url" => "https://x/1"}], checkpoint: "v1"} =
             Runtime.run("fake_subscription", first, wd, registry: :sub_registry)

    # Feed the issued checkpoint back: the plugin recognizes it and reports nothing new.
    second = %SubscriptionRequest{subscription_id: "s", checkpoint: "v1"}

    assert %SubscriptionResult{items: [], checkpoint: "v1"} =
             Runtime.run("fake_subscription", second, wd, registry: :sub_registry)
  end

  @tag :tmp_dir
  test "subprocess subscription returns items + checkpoint and receives the checkpoint", %{tmp_dir: wd} do
    req = %SubscriptionRequest{subscription_id: "s", checkpoint: "prev-cursor", config: %{}}

    assert %SubscriptionResult{items: [%{"url" => "https://feed/1"}], checkpoint: "etag-xyz"} =
             Runtime.run("sub_feed", req, wd, registry: :sub_registry, timeout: 10_000)

    # The checkpoint we sent was serialized into request.json for the plugin to read.
    assert File.read!(Path.join(wd, "request.json")) =~ "prev-cursor"
  end
end
```

- [ ] **Step 4: Run test to verify it fails, then passes**

Run: `mix test test/cham/plugin/subscription_contract_test.exs`
Expected: FAIL first (fixtures/module missing), then PASS once Steps 1–2 are in place. No implementation code is needed — the runtime, transports, and registry already support the subscription path; this task only adds fixtures and proves the contract.

- [ ] **Step 5: Commit**

```bash
git add test/support/plugin_fixtures/fake_subscription.ex test/support/plugin_fixtures/sub_feed test/cham/plugin/subscription_contract_test.exs
git commit -m "test(v3): cover the subscription invocation contract (both classes)"
```

## Task 11: Green the full quality gate

**Files:**
- Modify: `.sobelow-conf` (add the two new by-design file-access/command modules to `ignore_files`)

The subprocess transport spawns a `Port` and runs `System.cmd("kill", …)`, and the registry reads the plugins root via `File.ls`/`File.regular?` with computed paths — exactly the by-design, single-user, local operations already allowlisted for `script_runner.ex` and `layout.ex`. Sobelow flags these as Low-confidence `Traversal`/command findings; suppress them with justification.

- [ ] **Step 1: Add the new modules to `.sobelow-conf`**

Extend the `ignore_files` list and the justifying comment:

```elixir
  ignore_files: [
    "lib/cham/archive/layout.ex",
    "lib/cham/config/manager.ex",
    "lib/cham/plugin/transport/subprocess.ex",
    "lib/cham/plugin/registry.ex"
  ],
```

(The `script_runner.ex` entry was already removed in Task 0.) And add to the justifying comment block (after the `config/manager.ex` line):

```
#     - lib/cham/plugin/transport/subprocess.ex  (one-shot plugin port: request.json/output.json
#                                                  read/write + Port spawn + kill of the local subprocess)
#     - lib/cham/plugin/registry.ex              (scans the configured plugins root for manifests)
```

- [ ] **Step 2: Format the new code**

Run: `mix format`
Then verify nothing else drifted: `mix format --check-formatted`
Expected: exit 0.

- [ ] **Step 3: Run the fast gate**

Run: `just check-fast`
Expected: exit 0 (format-check, compile with `--warnings-as-errors`, credo --strict, sobelow, full test suite).

If credo flags complexity in `Cham.Plugin.Transport.Subprocess` `collect/5` or `decode_result/3`, do NOT restructure blindly — the `with`/`receive` shapes are intentional. Address any genuine finding (e.g. an unused alias, a missing `@moduledoc`) and re-run.

- [ ] **Step 4: Run the full gate (incl. dialyzer)**

Ensure Postgres is up first: `docker compose up -d postgres`
Run: `just check`
Expected: exit 0. Dialyzer success-types the typed-artifact contract across the polyglot boundary (the Phase 0a.5 reason for adding it). If dialyzer reports a genuinely unavoidable opaque/contract false positive in the new modules, add a narrowly-scoped entry to `.dialyzer_ignore.exs` with a comment — but first confirm it is a false positive, not a real type error.

- [ ] **Step 5: Commit**

```bash
git add .sobelow-conf
git commit -m "chore(v3): allowlist plugin subprocess/registry file-access in sobelow + green the gate"
```

---

## Self-Review (run by the plan author before handoff)

**Spec coverage** (each item maps to a task):
- Manifest + packaging + validation (§3) → Task 1.
- Typed-artifact vocabulary (§5.1) → Task 2; enforced at registration → Task 7.
- Wire protocol request/result shapes (§4, §5.3, §5.4, §6) + `waiting_for_input → unsupported` → Task 3.
- Progress events / EventBus forwarding (§4, §9) → Task 4 (struct) + Tasks 5–6 (forwarding).
- In-process behaviours `manifest/0` + `perform/2` + optional `can_process/1` (§5.2, §8) → Task 4.
- In-process transport (fast path, §4) → Task 5.
- Subprocess transport: `request.json` in / `output.json` out, stdout JSONL, stderr→log, stale-output deletion, crash/timeout → `failed(:error)` (§4, §9) → Task 6.
- `can_process` probe entrypoint (§5.2) → Tasks 5, 6 (both classes), 8.
- Registry/discovery, config-schema registration, vocabulary build, disabled/malformed skip (§3.3, §8) → Task 7.
- Unified class-based dispatch (§4 "callers never know which") → Task 8.
- Working-dir provisioning via Layout (§1 dependency) → Task 9 (`stage_path/2`); supervision + config namespace (§8) → Task 9.
- Subscription invocation contract + checkpoint round-trip (§6, §10) → Task 10.
- `{:query_can_process}` directive name / probe-fact shape (§5.5) → **frozen, not implemented** (Phase 2/4). No task; the probe *mechanism* (Tasks 5/6/8) is what Phase 1 owes, and the directive is documented in the spec. Correct per §11.
- Versioning `manifest.version` (§5.6) → carried on the Manifest struct (Task 1); stamping onto produced artifacts is Phase 4 (no artifact persistence in Phase 1). Correct per §11.
- Reserved kinds `subscriber`/`integration` accepted by parser, no invocation path (§7) → Task 1 (parser accepts; tested) + absence of dispatch in Task 8.

**Quality gate** → Task 11 (format/credo/sobelow/dialyzer/test all green).

**Type consistency check:** `StageResult{outcome, category, artifacts, item_metadata, provenance}`, `SubscriptionResult{items, checkpoint}`, `Input{type, labels, filenames, input_path}`, and the request structs are referenced identically across Tasks 3, 5, 6, 8, 10. `Manifest` fields (`class`, `source`, `entrypoints.{perform,can_process}`, `inputs`/`outputs` as `%{type, labels}`, `declares_types`, `config_schema`) are consistent across Tasks 1, 5, 6, 7, 9, 10. `Registry.lookup/2 → {:ok, manifest} | :error` and `discover/1 → {catalog, vocabulary}` are used consistently in Tasks 7, 8, 10. `Events.from_line/3 → {:ok, event} | :ignore` and `Events.topic/1` consistent across Tasks 4, 6.

**Deferred (explicitly NOT built, per §11):** `plan`/executor implementations; subscription scheduler/persistence/submit; `subscriber`/`integration` dispatchers; `waiting_for_input` resume; on-disk typed layouts; host-managed long-lived workers.

---

## Execution Handoff

Per the project's CLAUDE.md, execute this plan **subagent-driven** (one fresh subagent per task → spec-compliance review → code-quality review for logic-bearing tasks), committing each task on `v3-ingestion-rework`. Keep `checkpoint.md` and the WARC spec doc out of commits. The branch is local/unpushed; advance `master` only later (rebase + `git push . HEAD:master`), and only when the user asks.

