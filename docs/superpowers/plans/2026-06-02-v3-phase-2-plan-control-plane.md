# v3 Phase 2 — Pure `plan/2` Control Plane Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the pure logical layer of the v3 ingestion pipeline — `plan(catalog, facts)` and the `Catalog`/`Facts`/`Outcome` data contracts it reasons over — fully unit-tested from hand-built fixtures, with no Oban, DB, clock, or in-flight state.

**Architecture:** `plan/2` is a deterministic pure function. It evaluates three regimes in order: a serial **capture** walk over `catalog.capture_order`; then a combined **extract + process** frontier (extract = eager fan-out, process = per-component goal-directed backward DAG); then a **terminal** status. A uniform candidate-walk rule (any non-`produced` outcome advances) drives all goals; failure category is metadata, not a gate. `{:query_can_process, …}` is emitted before `{:run, …}` whenever a frontier stage advertises a `can_process` probe and has no probe fact yet.

**Tech Stack:** Elixir, ExUnit. Reuses `Cham.Plugin.Manifest` (Phase 1) as the per-stage catalog entry.

**Spec:** `docs/superpowers/specs/2026-06-02-v3-phase-2-plan-control-plane-design.md`. Read it before starting; section references below (e.g. §7.1) point into it.

---

## File Structure

| File | Responsibility |
|---|---|
| `lib/cham/plan/outcome.ex` | `Cham.Plan.Outcome` — one terminal outcome record (in-memory shape). Struct only. |
| `lib/cham/plan/facts.ex` | `Cham.Plan.Facts` — per-snapshot facts struct + pure query helpers (`outcome/3`, `probe/3`, `available_types/2`, `produced?/3`). |
| `lib/cham/plan/catalog.ex` | `Cham.Plan.Catalog` — system-level config view + `probes?/2` (uniform probe-capability flag across both plugin classes). |
| `lib/cham/plan.ex` | `Cham.Plan` — public `plan/2`, the three regimes, terminal tiers. |
| `test/cham/plan/facts_test.exs` | Facts query-helper tests. |
| `test/cham/plan/catalog_test.exs` | Catalog `probes?/2` tests. |
| `test/cham/plan_test.exs` | `plan/2` behavior tests (capture walk, frontiers, probe-first, terminal tiers, determinism). |
| `test/support/plan_fixtures.ex` | Shared `Manifest`/`Catalog`/`Facts` fixture builders for the tests. |

**Decisions locked here (consistent with the spec):**
- `stage_ref :: {stage_id :: String.t(), component_id :: String.t() | nil}` — `component_id` is `nil` for capture and extract-on-snapshot.
- Producer ordering: **capture** uses `catalog.capture_order`; all other goals order competing producers deterministically by `stage_id` (the spec defines a config order only for capture). Frontier lists are sorted before return so the same `(catalog, facts)` always yields the same decision.
- `available_types(facts, component_id)` treats a component's own (`component_id == id`) **and** snapshot-level (`component_id == nil`) produced artifacts as available to that component.

---

## Task 1: `Cham.Plan.Outcome` and `Cham.Plan.Facts` structs + Facts query helpers

**Files:**
- Create: `lib/cham/plan/outcome.ex`
- Create: `lib/cham/plan/facts.ex`
- Test: `test/cham/plan/facts_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/cham/plan/facts_test.exs
defmodule Cham.Plan.FactsTest do
  use ExUnit.Case, async: true
  alias Cham.Plan.{Facts, Outcome}

  defp facts(outcomes, probes \\ []) do
    %Facts{
      item_id: "i1",
      snapshot_id: "s1",
      submitted_url: "https://example.com",
      outcomes: outcomes,
      probes: probes
    }
  end

  defp produced(stage_id, component_id, types) do
    %Outcome{
      stage_id: stage_id,
      component_id: component_id,
      status: :produced,
      version: 1,
      artifacts: Enum.map(types, &%{type: &1, labels: %{}, category: :extracted})
    }
  end

  test "outcome/3 finds the outcome for a (stage, component) pair" do
    o = produced("extract_article", nil, ["article_markdown"])
    f = facts([o])
    assert Facts.outcome(f, "extract_article", nil) == o
    assert Facts.outcome(f, "extract_article", "c1") == nil
    assert Facts.outcome(f, "missing", nil) == nil
  end

  test "probe/3 returns the recorded result or nil" do
    f = facts([], [%{stage_id: "yt_dlp", component_id: nil, result: :applicable}])
    assert Facts.probe(f, "yt_dlp", nil) == :applicable
    assert Facts.probe(f, "yt_dlp", "c1") == nil
    assert Facts.probe(f, "other", nil) == nil
  end

  test "available_types/2 unions component-level and snapshot-level produced types" do
    f =
      facts([
        produced("capture", nil, ["html_capture"]),
        produced("extract_video", "c1", ["video"]),
        produced("extract_audio", "c2", ["audio"])
      ])

    assert Facts.available_types(f, "c1") == MapSet.new(["html_capture", "video"])
    assert Facts.available_types(f, nil) == MapSet.new(["html_capture"])
  end

  test "available_types/2 ignores non-produced outcomes" do
    failed = %Outcome{stage_id: "x", component_id: nil, status: :failed, failure_category: :error, version: 1}
    f = facts([failed])
    assert Facts.available_types(f, nil) == MapSet.new([])
  end

  test "produced?/3 is true when a produced artifact of the type exists in scope" do
    f = facts([produced("extract_video", "c1", ["video"])])
    assert Facts.produced?(f, "video", "c1")
    refute Facts.produced?(f, "video", "c2")
    refute Facts.produced?(f, "audio", "c1")
  end

  test "ran?/2 is true when any outcome exists for the stage, regardless of component" do
    f = facts([produced("extract_video", "c1", ["video"])])
    assert Facts.ran?(f, "extract_video")
    refute Facts.ran?(f, "extract_article")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/cham/plan/facts_test.exs`
Expected: FAIL — `Cham.Plan.Outcome.__struct__/1` / `Cham.Plan.Facts` undefined (compile error).

- [ ] **Step 3: Write `Cham.Plan.Outcome`**

```elixir
# lib/cham/plan/outcome.ex
defmodule Cham.Plan.Outcome do
  @moduledoc """
  One terminal outcome of a stage run against a `(stage_id, component_id)` pair.
  The in-memory shape of the durable outcome record (Phase 3 populates it from
  the archive/DB; Phase 4 records it). `failure_category` is set only when
  `status` is `:failed` and is metadata (it does not gate the candidate walk).
  """

  @enforce_keys [:stage_id, :status, :version]
  defstruct [:stage_id, :component_id, :status, :failure_category, :version, artifacts: []]

  @type artifact :: %{
          type: String.t(),
          labels: map(),
          category: :capture | :extracted | :derived
        }

  @type t :: %__MODULE__{
          stage_id: String.t(),
          component_id: String.t() | nil,
          status: :produced | :not_applicable | :failed,
          failure_category: :blocked | :unsupported | :bad_input | :error | nil,
          version: pos_integer(),
          artifacts: [artifact()]
        }
end
```

- [ ] **Step 4: Write `Cham.Plan.Facts`**

```elixir
# lib/cham/plan/facts.ex
defmodule Cham.Plan.Facts do
  @moduledoc """
  Per-snapshot facts the planner reasons over, built only from durable terminal
  outcomes — never in-flight state. Phase 3's projection populates this from the
  DB index / on-disk archive; Phase 2 builds it by hand in tests.
  """
  alias Cham.Plan.Outcome

  @enforce_keys [:item_id, :snapshot_id, :submitted_url]
  defstruct [
    :item_id,
    :snapshot_id,
    :submitted_url,
    user_metadata: %{},
    components: [],
    outcomes: [],
    probes: []
  ]

  @type component :: %{id: String.t(), content_type: String.t()}
  @type probe :: %{
          stage_id: String.t(),
          component_id: String.t() | nil,
          result: :applicable | :not_applicable
        }

  @type t :: %__MODULE__{
          item_id: String.t(),
          snapshot_id: String.t(),
          submitted_url: String.t(),
          user_metadata: map(),
          components: [component()],
          outcomes: [Outcome.t()],
          probes: [probe()]
        }

  @doc "The terminal outcome recorded for a `(stage_id, component_id)` pair, or nil."
  @spec outcome(t(), String.t(), String.t() | nil) :: Outcome.t() | nil
  def outcome(%__MODULE__{outcomes: outcomes}, stage_id, component_id) do
    Enum.find(outcomes, &(&1.stage_id == stage_id and &1.component_id == component_id))
  end

  @doc "The recorded can_process probe result for a pair, or nil if not yet probed."
  @spec probe(t(), String.t(), String.t() | nil) :: :applicable | :not_applicable | nil
  def probe(%__MODULE__{probes: probes}, stage_id, component_id) do
    case Enum.find(probes, &(&1.stage_id == stage_id and &1.component_id == component_id)) do
      %{result: result} -> result
      nil -> nil
    end
  end

  @doc """
  The set of artifact types produced and available to `component_id`: that
  component's own produced artifacts unioned with snapshot-level (`nil`) ones.
  """
  @spec available_types(t(), String.t() | nil) :: MapSet.t(String.t())
  def available_types(%__MODULE__{outcomes: outcomes}, component_id) do
    for o <- outcomes,
        o.status == :produced,
        o.component_id in [component_id, nil],
        a <- o.artifacts,
        into: MapSet.new(),
        do: a.type
  end

  @doc "Whether a produced artifact of `type` exists in scope for `component_id`."
  @spec produced?(t(), String.t(), String.t() | nil) :: boolean()
  def produced?(%__MODULE__{outcomes: outcomes}, type, component_id) do
    Enum.any?(outcomes, fn o ->
      o.status == :produced and o.component_id in [component_id, nil] and
        Enum.any?(o.artifacts, &(&1.type == type))
    end)
  end

  @doc """
  Whether any terminal outcome exists for `stage_id`, regardless of component.
  Used for the snapshot-once "has this extract stage already run" check — an
  extract stage that produces a component records its outcome against that
  component, not against `nil`.
  """
  @spec ran?(t(), String.t()) :: boolean()
  def ran?(%__MODULE__{outcomes: outcomes}, stage_id) do
    Enum.any?(outcomes, &(&1.stage_id == stage_id))
  end
end
```

- [ ] **Step 5: Run test to verify it passes**

Run: `mix test test/cham/plan/facts_test.exs`
Expected: PASS (5 tests).

- [ ] **Step 6: Commit**

```bash
git add lib/cham/plan/outcome.ex lib/cham/plan/facts.ex test/cham/plan/facts_test.exs
git commit -m "feat(v3): Cham.Plan Outcome/Facts structs + Facts query helpers"
```

---

## Task 2: `Cham.Plan.Catalog` struct + `probes?/2`

**Files:**
- Create: `lib/cham/plan/catalog.ex`
- Test: `test/cham/plan/catalog_test.exs`

`probes?/2` is the uniform probe-capability flag `plan` reads. It must work for **both** plugin classes: a subprocess plugin advertises the probe via `entrypoints.can_process` (a string); an in-process plugin advertises it via an exported `can_process/1` callback on its module (plugin-runtime §5.2).

- [ ] **Step 1: Write the failing test**

```elixir
# test/cham/plan/catalog_test.exs
defmodule Cham.Plan.CatalogTest do
  use ExUnit.Case, async: true
  alias Cham.Plan.Catalog
  alias Cham.Plugin.Manifest

  defp manifest(attrs) do
    base = %Manifest{
      id: "m",
      kind: :stage,
      class: :subprocess,
      source: {:dir, "x"},
      phase: :extract,
      entrypoints: %{perform: "run.py", can_process: nil}
    }

    struct!(base, attrs)
  end

  defp catalog(manifests) do
    %Catalog{
      stage_manifests: Map.new(manifests, &{&1.id, &1}),
      capture_order: [],
      classification_desired: %{}
    }
  end

  test "probes?/2 is true for a subprocess stage with a can_process entrypoint" do
    c = catalog([manifest(id: "p", entrypoints: %{perform: "run.py", can_process: "probe.py"})])
    assert Catalog.probes?(c, "p")
  end

  test "probes?/2 is false for a subprocess stage without a can_process entrypoint" do
    c = catalog([manifest(id: "p", entrypoints: %{perform: "run.py", can_process: nil})])
    refute Catalog.probes?(c, "p")
  end

  test "probes?/2 reflects an in-process module's exported can_process/1" do
    c =
      catalog([
        manifest(
          id: "with_probe",
          class: :in_process,
          source: {:module, Cham.Plan.CatalogTest.ProbeStage}
        ),
        manifest(
          id: "no_probe",
          class: :in_process,
          source: {:module, Cham.Plan.CatalogTest.PlainStage}
        )
      ])

    assert Catalog.probes?(c, "with_probe")
    refute Catalog.probes?(c, "no_probe")
  end

  test "probes?/2 is false for an unknown stage id" do
    refute Catalog.probes?(catalog([]), "ghost")
  end

  defmodule ProbeStage do
    def can_process(_input), do: true
  end

  defmodule PlainStage do
    def perform(_a, _b), do: :ok
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/cham/plan/catalog_test.exs`
Expected: FAIL — `Cham.Plan.Catalog` undefined.

- [ ] **Step 3: Write `Cham.Plan.Catalog`**

```elixir
# lib/cham/plan/catalog.ex
defmodule Cham.Plan.Catalog do
  @moduledoc """
  The system-level `config` value the planner reads: a view over the registry's
  `kind: :stage` manifests plus config-derived orderings. Phase 4 wires this
  from `Cham.Plugin.Registry` + `cham.toml`; Phase 2 builds it by hand in tests.
  """
  alias Cham.Plugin.Manifest

  @enforce_keys [:stage_manifests, :capture_order, :classification_desired]
  defstruct stage_manifests: %{}, capture_order: [], classification_desired: %{}

  @type t :: %__MODULE__{
          stage_manifests: %{optional(String.t()) => Manifest.t()},
          capture_order: [String.t()],
          classification_desired: %{optional(String.t()) => [String.t()]}
        }

  @doc """
  Whether a stage advertises the cheap `can_process` probe. Subprocess plugins
  declare it via `entrypoints.can_process`; in-process plugins via an exported
  `can_process/1` callback (plugin-runtime §5.2). Unknown id ⇒ false.
  """
  @spec probes?(t(), String.t()) :: boolean()
  def probes?(%__MODULE__{stage_manifests: manifests}, stage_id) do
    case Map.get(manifests, stage_id) do
      %Manifest{entrypoints: %{can_process: cp}} when is_binary(cp) ->
        true

      %Manifest{class: :in_process, source: {:module, module}} ->
        function_exported?(module, :can_process, 1)

      _ ->
        false
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/cham/plan/catalog_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/cham/plan/catalog.ex test/cham/plan/catalog_test.exs
git commit -m "feat(v3): Cham.Plan.Catalog with uniform probes?/2 capability flag"
```

---

## Task 3: shared test fixtures

**Files:**
- Create: `test/support/plan_fixtures.ex`

Centralizes `Manifest`/`Catalog`/`Facts`/`Outcome` builders so the `plan/2` tests in Tasks 4–7 stay readable. Confirm `test/support` is compiled by checking `mix.exs` has `elixirc_paths(:test)` include `"test/support"` (it does in this project — verify before adding).

- [ ] **Step 1: Verify test/support is on the test compile path**

Run: `grep -n "test/support" mix.exs`
Expected: a line like `defp elixirc_paths(:test), do: ["lib", "test/support"]`. If absent, add it before continuing.

- [ ] **Step 2: Write the fixtures module**

```elixir
# test/support/plan_fixtures.ex
defmodule Cham.PlanFixtures do
  @moduledoc "Builders for pure Cham.Plan unit tests."
  alias Cham.Plan.{Catalog, Facts, Outcome}
  alias Cham.Plugin.Manifest

  @doc "A stage manifest. Override any field via `attrs`."
  def manifest(id, attrs \\ []) do
    base = %Manifest{
      id: id,
      kind: :stage,
      class: :subprocess,
      source: {:dir, id},
      phase: :extract,
      version: 1,
      inputs: [],
      outputs: [],
      entrypoints: %{perform: "run", can_process: nil}
    }

    struct!(base, attrs)
  end

  @doc "Shorthand for a typed I/O declaration."
  def io(type, labels \\ %{}), do: %{type: type, labels: labels}

  @doc "A catalog from a list of manifests + optional capture order / desired map."
  def catalog(manifests, opts \\ []) do
    %Catalog{
      stage_manifests: Map.new(manifests, &{&1.id, &1}),
      capture_order: Keyword.get(opts, :capture_order, []),
      classification_desired: Keyword.get(opts, :classification_desired, %{})
    }
  end

  @doc "A facts value. Override `:components`, `:outcomes`, `:probes` via opts."
  def facts(opts \\ []) do
    %Facts{
      item_id: "item-1",
      snapshot_id: "snap-1",
      submitted_url: "https://example.com/x",
      user_metadata: %{},
      components: Keyword.get(opts, :components, []),
      outcomes: Keyword.get(opts, :outcomes, []),
      probes: Keyword.get(opts, :probes, [])
    }
  end

  def produced(stage_id, component_id, artifacts) do
    %Outcome{
      stage_id: stage_id,
      component_id: component_id,
      status: :produced,
      version: 1,
      artifacts: Enum.map(artifacts, fn {type, category} -> %{type: type, labels: %{}, category: category} end)
    }
  end

  def not_applicable(stage_id, component_id) do
    %Outcome{stage_id: stage_id, component_id: component_id, status: :not_applicable, version: 1}
  end

  def failed(stage_id, component_id, category) do
    %Outcome{
      stage_id: stage_id,
      component_id: component_id,
      status: :failed,
      failure_category: category,
      version: 1
    }
  end

  def probe(stage_id, component_id, result) do
    %{stage_id: stage_id, component_id: component_id, result: result}
  end

  @doc "A process-phase stage: one typed input -> one typed output. Override via `attrs`."
  def proc(id, in_type, out_type, attrs \\ []) do
    manifest(id, [phase: :process, inputs: [io(in_type)], outputs: [io(out_type)]] ++ attrs)
  end

  @doc "The snapshot-level capture outcome (passe_partout -> html_capture)."
  def capture_produced, do: produced("passe_partout", nil, [{"html_capture", :capture}])

  @doc "Facts with capture produced, plus any extra outcomes."
  def captured(extra_outcomes \\ []) do
    facts(outcomes: [capture_produced()] ++ extra_outcomes)
  end

  @doc "A catalog with passe_partout as the sole capture stage, plus `extra_stages`."
  def with_capture(extra_stages, opts \\ []) do
    catalog(
      [manifest("passe_partout", phase: :bootstrap)] ++ extra_stages,
      Keyword.put_new(opts, :capture_order, ["passe_partout"])
    )
  end

  @doc "Facts: capture produced + one extracted component artifact (stage id \"extract\")."
  def extracted(content_type, component_id, extracted_type) do
    facts(
      components: [%{id: component_id, content_type: content_type}],
      outcomes: [
        capture_produced(),
        produced("extract", component_id, [{extracted_type, :extracted}])
      ]
    )
  end
end
```

- [ ] **Step 3: Verify it compiles**

Run: `mix test test/cham/plan/facts_test.exs`
Expected: PASS (the existing suite still compiles with the new support file present).

- [ ] **Step 4: Commit**

```bash
git add test/support/plan_fixtures.ex
git commit -m "test(v3): shared Cham.Plan fixture builders"
```

---

## Task 4: `plan/2` — capture regime + terminal status

**Files:**
- Create: `lib/cham/plan.ex`
- Test: `test/cham/plan_test.exs`

This task ships a working `plan/2` for the **capture** regime (serial walk over `capture_order`, §7.1 regime 1) and the **terminal** tiers (§8). The extract/process frontiers arrive in Tasks 5–6; until then `downstream/2` goes straight to a terminal status, which is correct whenever no eligible non-capture stage exists. Terminal tests below use catalogs whose non-capture stages already carry outcomes (hence never eligible), so they stay valid as later tasks add frontier logic.

- [ ] **Step 1: Write the failing test**

```elixir
# test/cham/plan_test.exs
defmodule Cham.PlanTest do
  use ExUnit.Case, async: true
  import Cham.PlanFixtures
  alias Cham.Plan

  describe "capture regime" do
    test "runs the first untried capture candidate (no probe capability)" do
      cat =
        catalog(
          [manifest("yt_dlp", phase: :bootstrap), manifest("passe_partout", phase: :bootstrap)],
          capture_order: ["yt_dlp", "passe_partout"]
        )

      assert Plan.plan(cat, facts()) == {:run, [{"yt_dlp", nil}]}
    end

    test "emits query_can_process for an untried probe-capable candidate" do
      cat =
        catalog(
          [manifest("yt_dlp", phase: :bootstrap, entrypoints: %{perform: "p", can_process: "c"})],
          capture_order: ["yt_dlp"]
        )

      assert Plan.plan(cat, facts()) == {:query_can_process, [{"yt_dlp", nil}]}
    end

    test "runs a candidate once its probe says applicable" do
      cat =
        catalog(
          [manifest("yt_dlp", phase: :bootstrap, entrypoints: %{perform: "p", can_process: "c"})],
          capture_order: ["yt_dlp"]
        )

      f = facts(probes: [probe("yt_dlp", nil, :applicable)])
      assert Plan.plan(cat, f) == {:run, [{"yt_dlp", nil}]}
    end

    test "falls through on a not_applicable probe to the next candidate" do
      cat =
        catalog(
          [
            manifest("yt_dlp", phase: :bootstrap, entrypoints: %{perform: "p", can_process: "c"}),
            manifest("passe_partout", phase: :bootstrap)
          ],
          capture_order: ["yt_dlp", "passe_partout"]
        )

      f = facts(probes: [probe("yt_dlp", nil, :not_applicable)])
      assert Plan.plan(cat, f) == {:run, [{"passe_partout", nil}]}
    end

    test "falls through on any non-produced outcome (not_applicable, failed)" do
      cat =
        catalog(
          [
            manifest("yt_dlp", phase: :bootstrap),
            manifest("reddit", phase: :bootstrap),
            manifest("passe_partout", phase: :bootstrap)
          ],
          capture_order: ["yt_dlp", "reddit", "passe_partout"]
        )

      f = facts(outcomes: [not_applicable("yt_dlp", nil), failed("reddit", nil, :bad_input)])
      assert Plan.plan(cat, f) == {:run, [{"passe_partout", nil}]}
    end

    test "exhausted capture set with nothing produced is terminal :failed" do
      cat =
        catalog([manifest("yt_dlp", phase: :bootstrap)], capture_order: ["yt_dlp"])

      f = facts(outcomes: [failed("yt_dlp", nil, :blocked)])
      assert Plan.plan(cat, f) == {:terminal, :failed}
    end
  end

  describe "terminal status (no eligible non-capture stages)" do
    setup do
      cap = manifest("passe_partout", phase: :bootstrap)
      {:ok, cap: cap}
    end

    test "captured, no components, an extractor failed => :incomplete", %{cap: cap} do
      cat =
        catalog([cap, manifest("extract_article", phase: :extract)],
          capture_order: ["passe_partout"]
        )

      f =
        facts(
          components: [],
          outcomes: [
            produced("passe_partout", nil, [{"html_capture", :capture}]),
            failed("extract_article", nil, :bad_input)
          ]
        )

      assert Plan.plan(cat, f) == {:terminal, :incomplete}
    end

    test "captured, no components, all extractors not_applicable => :complete", %{cap: cap} do
      cat =
        catalog([cap, manifest("extract_article", phase: :extract)],
          capture_order: ["passe_partout"]
        )

      f =
        facts(
          components: [],
          outcomes: [
            produced("passe_partout", nil, [{"html_capture", :capture}]),
            not_applicable("extract_article", nil)
          ]
        )

      assert Plan.plan(cat, f) == {:terminal, :complete}
    end

    test "captured + extracted, all desired produced => :complete", %{cap: cap} do
      cat =
        catalog([cap],
          capture_order: ["passe_partout"],
          classification_desired: %{"article" => ["summary"]}
        )

      f =
        facts(
          components: [%{id: "c1", content_type: "article"}],
          outcomes: [
            produced("passe_partout", nil, [{"html_capture", :capture}]),
            produced("summarize", "c1", [{"summary", :derived}])
          ]
        )

      assert Plan.plan(cat, f) == {:terminal, :complete}
    end

    test "captured + extracted, a desired artifact unreachable => :incomplete", %{cap: cap} do
      cat =
        catalog([cap],
          capture_order: ["passe_partout"],
          classification_desired: %{"article" => ["summary"]}
        )

      f =
        facts(
          components: [%{id: "c1", content_type: "article"}],
          outcomes: [produced("passe_partout", nil, [{"html_capture", :capture}])]
        )

      # No process producer for "summary" exists in the catalog, so the frontier
      # is empty and the unmet desired artifact is unreachable.
      assert Plan.plan(cat, f) == {:terminal, :incomplete}
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/cham/plan_test.exs`
Expected: FAIL — `Cham.Plan` undefined.

- [ ] **Step 3: Write `Cham.Plan` (capture + terminal; frontier stubbed to empty)**

```elixir
# lib/cham/plan.ex
defmodule Cham.Plan do
  @moduledoc """
  The pure logical layer of the v3 ingestion pipeline. `plan/2` is a
  deterministic function of `(catalog, facts)` — no Oban, DB, clock, or
  in-flight state. It evaluates three regimes in order: a serial capture walk,
  a combined extract+process frontier, then a terminal status.

  See `docs/superpowers/specs/2026-06-02-v3-phase-2-plan-control-plane-design.md`.
  """
  alias Cham.Plan.{Catalog, Facts}
  alias Cham.Plugin.Manifest

  @type stage_ref :: {String.t(), String.t() | nil}
  @type status :: :complete | :incomplete | :failed
  @type directive ::
          {:run, [stage_ref()]}
          | {:query_can_process, [stage_ref()]}
          | {:terminal, status()}

  @spec plan(Catalog.t(), Facts.t()) :: directive()
  def plan(%Catalog{} = catalog, %Facts{} = facts) do
    case capture_regime(catalog, facts) do
      {:decision, directive} -> directive
      :captured -> downstream(catalog, facts)
    end
  end

  # --- Capture regime (serial, exclusive, ordered-with-fallback; §7.1) ---

  defp capture_regime(catalog, facts), do: walk_capture(catalog.capture_order, catalog, facts)

  defp walk_capture([], _catalog, _facts), do: {:decision, {:terminal, :failed}}

  defp walk_capture([id | rest], catalog, facts) do
    case Facts.outcome(facts, id, nil) do
      %{status: :produced} -> :captured
      %{} -> walk_capture(rest, catalog, facts)
      nil -> capture_candidate(id, rest, catalog, facts)
    end
  end

  defp capture_candidate(id, rest, catalog, facts) do
    case Facts.probe(facts, id, nil) do
      :not_applicable -> walk_capture(rest, catalog, facts)
      :applicable -> {:decision, {:run, [{id, nil}]}}
      nil -> {:decision, run_or_probe(catalog, id, nil)}
    end
  end

  # Route-and-run unless the stage advertises a cheap probe and hasn't been probed.
  defp run_or_probe(catalog, id, component_id) do
    if Catalog.probes?(catalog, id) do
      {:query_can_process, [{id, component_id}]}
    else
      {:run, [{id, component_id}]}
    end
  end

  # --- Downstream (extract + process); frontier filled in Tasks 5-6 ---

  defp downstream(catalog, facts), do: {:terminal, terminal_status(catalog, facts)}

  # --- Terminal tiers (§8) ---

  defp terminal_status(catalog, facts) do
    cond do
      facts.components == [] and any_extract_failed?(catalog, facts) -> :incomplete
      facts.components == [] -> :complete
      all_desired_produced?(catalog, facts) -> :complete
      true -> :incomplete
    end
  end

  defp any_extract_failed?(catalog, facts) do
    Enum.any?(facts.outcomes, fn o ->
      o.status == :failed and stage_phase(catalog, o.stage_id) == :extract
    end)
  end

  defp all_desired_produced?(catalog, facts) do
    Enum.all?(facts.components, fn c ->
      catalog.classification_desired
      |> Map.get(c.content_type, [])
      |> Enum.all?(&Facts.produced?(facts, &1, c.id))
    end)
  end

  defp stage_phase(catalog, id) do
    case Map.get(catalog.stage_manifests, id) do
      %Manifest{phase: phase} -> phase
      _ -> nil
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/cham/plan_test.exs`
Expected: PASS (capture regime: 6 tests; terminal status: 4 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/cham/plan.ex test/cham/plan_test.exs
git commit -m "feat(v3): Cham.Plan capture regime + terminal status tiers"
```

---

## Task 5: extract frontier (eager fan-out) + probe-first partition

**Files:**
- Modify: `lib/cham/plan.ex` (replace `downstream/2`; add `extract_frontier/2`, `decide/3`, `partition_probes/3`, `inputs_satisfied?/2`)
- Test: `test/cham/plan_test.exs` (add an `extract frontier` describe block)

Once capture is produced, all extract-phase stages whose declared input types are available and that have no terminal outcome run together (§7.1). The combined frontier is partitioned **probe-first**: if any frontier stage advertises `can_process` and lacks a probe fact, emit `{:query_can_process, …}`; otherwise `{:run, …}` (§7.2). Lists are sorted for determinism.

- [ ] **Step 1: Write the failing test (append to `test/cham/plan_test.exs`)**

`captured/0,1` and `with_capture/1` come from `Cham.PlanFixtures` (already imported).

```elixir
  describe "extract frontier" do

    test "fans out all applicable extract stages at once" do
      cat =
        with_capture([
          manifest("extract_article", phase: :extract, inputs: [io("html_capture")]),
          manifest("extract_video", phase: :extract, inputs: [io("html_capture")])
        ])

      assert Plan.plan(cat, captured()) ==
               {:run, [{"extract_article", nil}, {"extract_video", nil}]}
    end

    test "excludes an extract stage whose inputs are not yet available" do
      cat =
        with_capture([
          manifest("extract_article", phase: :extract, inputs: [io("html_capture")]),
          manifest("transcribe", phase: :extract, inputs: [io("audio")])
        ])

      assert Plan.plan(cat, captured()) == {:run, [{"extract_article", nil}]}
    end

    test "excludes an extract stage that already has a terminal outcome" do
      cat =
        with_capture([
          manifest("extract_article", phase: :extract, inputs: [io("html_capture")]),
          manifest("extract_video", phase: :extract, inputs: [io("html_capture")])
        ])

      f = captured([not_applicable("extract_article", nil)])
      assert Plan.plan(cat, f) == {:run, [{"extract_video", nil}]}
    end

    test "probe-first: emits query_can_process before running when a frontier stage needs probing" do
      cat =
        with_capture([
          manifest("extract_article", phase: :extract, inputs: [io("html_capture")]),
          manifest("extract_video",
            phase: :extract,
            inputs: [io("html_capture")],
            entrypoints: %{perform: "p", can_process: "c"}
          )
        ])

      assert Plan.plan(cat, captured()) == {:query_can_process, [{"extract_video", nil}]}
    end

    test "a probed-applicable extract stage joins the run frontier" do
      cat =
        with_capture([
          manifest("extract_video",
            phase: :extract,
            inputs: [io("html_capture")],
            entrypoints: %{perform: "p", can_process: "c"}
          )
        ])

      f = captured() |> Map.update!(:probes, fn _ -> [probe("extract_video", nil, :applicable)] end)
      assert Plan.plan(cat, f) == {:run, [{"extract_video", nil}]}
    end

    test "a probed-not_applicable extract stage is excluded from the frontier" do
      cat =
        with_capture([
          manifest("extract_video",
            phase: :extract,
            inputs: [io("html_capture")],
            entrypoints: %{perform: "p", can_process: "c"}
          )
        ])

      f = captured() |> Map.update!(:probes, fn _ -> [probe("extract_video", nil, :not_applicable)] end)
      # No components and no extractor failed => :complete.
      assert Plan.plan(cat, f) == {:terminal, :complete}
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/cham/plan_test.exs`
Expected: FAIL — the new tests get `{:terminal, _}` (the stubbed `downstream/2`) instead of `{:run, …}` / `{:query_can_process, …}`.

- [ ] **Step 3: Replace `downstream/2` and add the frontier helpers**

In `lib/cham/plan.ex`, replace the line:

```elixir
  defp downstream(catalog, facts), do: {:terminal, terminal_status(catalog, facts)}
```

with:

```elixir
  defp downstream(catalog, facts) do
    catalog
    |> extract_frontier(facts)
    |> decide(catalog, facts)
  end

  # Emit probes first (§7.2); else run the ready set; else fall to terminal.
  defp decide(frontier, catalog, facts) do
    {ready, probe_needed} = partition_probes(frontier, catalog, facts)

    cond do
      probe_needed != [] -> {:query_can_process, Enum.sort(probe_needed)}
      ready != [] -> {:run, Enum.sort(ready)}
      true -> {:terminal, terminal_status(catalog, facts)}
    end
  end

  # Eager fan-out: every extract stage that hasn't run, with inputs available,
  # not probe-rejected. Uses `ran?/2` (not `outcome/3`): an extract stage that
  # produces a component records its outcome against that component, so the
  # has-run check must match on the stage id alone.
  defp extract_frontier(catalog, facts) do
    available = Facts.available_types(facts, nil)

    for {id, m} <- catalog.stage_manifests,
        m.phase == :extract,
        not Facts.ran?(facts, id),
        Facts.probe(facts, id, nil) != :not_applicable,
        inputs_satisfied?(m, available),
        do: {id, nil}
  end

  # Ready = no probe needed (no can_process capability, or already probed).
  defp partition_probes(frontier, catalog, facts) do
    Enum.split_with(frontier, fn {id, component_id} ->
      not (Catalog.probes?(catalog, id) and is_nil(Facts.probe(facts, id, component_id)))
    end)
  end

  defp inputs_satisfied?(%Manifest{inputs: inputs}, available) do
    Enum.all?(inputs, fn %{type: type} -> MapSet.member?(available, type) end)
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/cham/plan_test.exs`
Expected: PASS (capture + terminal from Task 4 still green; 6 new extract-frontier tests pass).

- [ ] **Step 5: Commit**

```bash
git add lib/cham/plan.ex test/cham/plan_test.exs
git commit -m "feat(v3): Cham.Plan extract fan-out frontier + probe-first partition"
```

---

## Task 6: process frontier (per-component goal-directed backward DAG)

**Files:**
- Modify: `lib/cham/plan.ex` (replace `downstream/2`; add `process_frontier/2`, `component_frontier/4`, `produces_needed?/2`, `needed_types/2`, `expand_needed/2`, `producer_input_types/2`)
- Test: `test/cham/plan_test.exs` (add a `process frontier` describe block)

For each component, derive its desired artifact types (`classification_desired[content_type]`), compute the backward closure of types those producers transitively need, and admit process-phase stages that produce a needed type, have inputs satisfied for that component, have no outcome for that component, and are not probe-rejected (§7.1). The combined extract+process frontier still flows through `decide/3` (probe-first, sorted).

The backward closure (`needed_types/2`) gates *which* process stages are wanted; `inputs_satisfied?/2` gates *which are eligible now*. Expensive deep-chain stages stay out of the frontier until their inputs exist — so a `video → extract_audio → transcribe → summarize` chain surfaces one eligible stage at a time across successive `plan` calls.

- [ ] **Step 1: Write the failing test (append to `test/cham/plan_test.exs`)**

`extracted/3` (capture + one extracted component artifact) and `proc/3` (a process-phase stage) come from `Cham.PlanFixtures`.

```elixir
  describe "process frontier" do
    test "admits a process stage on the path to a desired artifact" do
      cat =
        catalog([manifest("passe_partout", phase: :bootstrap), proc("summarize", "article_markdown", "summary")],
          capture_order: ["passe_partout"],
          classification_desired: %{"article" => ["summary"]}
        )

      f = extracted("article", "c1", "article_markdown")
      assert Plan.plan(cat, f) == {:run, [{"summarize", "c1"}]}
    end

    test "surfaces only the currently-eligible stage of a deep chain" do
      cat =
        catalog(
          [
            manifest("passe_partout", phase: :bootstrap),
            proc("extract_audio", "video", "audio"),
            proc("transcribe", "audio", "transcript"),
            proc("summarize", "transcript", "summary")
          ],
          capture_order: ["passe_partout"],
          classification_desired: %{"video" => ["summary"]}
        )

      f = extracted("video", "c1", "video")
      # Only extract_audio has its input (video) available yet.
      assert Plan.plan(cat, f) == {:run, [{"extract_audio", "c1"}]}
    end

    test "advances the chain as upstream artifacts appear" do
      cat =
        catalog(
          [
            manifest("passe_partout", phase: :bootstrap),
            proc("extract_audio", "video", "audio"),
            proc("transcribe", "audio", "transcript"),
            proc("summarize", "transcript", "summary")
          ],
          capture_order: ["passe_partout"],
          classification_desired: %{"video" => ["summary"]}
        )

      f =
        "video"
        |> extracted("c1", "video")
        |> Map.update!(:outcomes, &(&1 ++ [produced("extract_audio", "c1", [{"audio", :extracted}])]))

      assert Plan.plan(cat, f) == {:run, [{"transcribe", "c1"}]}
    end

    test "excludes a process stage whose output is not desired" do
      cat =
        catalog(
          [
            manifest("passe_partout", phase: :bootstrap),
            proc("summarize", "article_markdown", "summary"),
            proc("embed", "article_markdown", "embedding")
          ],
          capture_order: ["passe_partout"],
          classification_desired: %{"article" => ["summary"]}
        )

      f = extracted("article", "c1", "article_markdown")
      # embed produces "embedding", which is not desired for an article.
      assert Plan.plan(cat, f) == {:run, [{"summarize", "c1"}]}
    end

    test "computes desired artifacts per component independently" do
      cat =
        catalog(
          [manifest("passe_partout", phase: :bootstrap), proc("summarize", "article_markdown", "summary")],
          capture_order: ["passe_partout"],
          classification_desired: %{"article" => ["summary"], "image" => []}
        )

      f =
        facts(
          components: [%{id: "c1", content_type: "article"}, %{id: "c2", content_type: "image"}],
          outcomes: [
            produced("passe_partout", nil, [{"html_capture", :capture}]),
            produced("extract", "c1", [{"article_markdown", :extracted}]),
            produced("extract_img", "c2", [{"image_file", :extracted}])
          ]
        )

      assert Plan.plan(cat, f) == {:run, [{"summarize", "c1"}]}
    end

    test "probe-first applies to process stages too" do
      cat =
        catalog(
          [
            manifest("passe_partout", phase: :bootstrap),
            proc("summarize", "article_markdown", "summary", entrypoints: %{perform: "p", can_process: "c"})
          ],
          capture_order: ["passe_partout"],
          classification_desired: %{"article" => ["summary"]}
        )

      f = extracted("article", "c1", "article_markdown")
      assert Plan.plan(cat, f) == {:query_can_process, [{"summarize", "c1"}]}
    end

    test "a desired artifact already produced leaves the frontier empty => :complete" do
      cat =
        catalog([manifest("passe_partout", phase: :bootstrap), proc("summarize", "article_markdown", "summary")],
          capture_order: ["passe_partout"],
          classification_desired: %{"article" => ["summary"]}
        )

      f =
        "article"
        |> extracted("c1", "article_markdown")
        |> Map.update!(:outcomes, &(&1 ++ [produced("summarize", "c1", [{"summary", :derived}])]))

      assert Plan.plan(cat, f) == {:terminal, :complete}
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/cham/plan_test.exs`
Expected: FAIL — process stages are never admitted yet, so these get `{:terminal, _}` instead of the expected `{:run, …}` / `{:query_can_process, …}`.

- [ ] **Step 3: Replace `downstream/2` and add the process-frontier helpers**

In `lib/cham/plan.ex`, replace:

```elixir
  defp downstream(catalog, facts) do
    catalog
    |> extract_frontier(facts)
    |> decide(catalog, facts)
  end
```

with:

```elixir
  defp downstream(catalog, facts) do
    (extract_frontier(catalog, facts) ++ process_frontier(catalog, facts))
    |> decide(catalog, facts)
  end

  # Per component: stages on a path to an unmet desired artifact, eligible now.
  defp process_frontier(catalog, facts) do
    for component <- facts.components,
        needed = needed_types(catalog, component.content_type),
        ref <- component_frontier(catalog, facts, component, needed),
        do: ref
  end

  defp component_frontier(catalog, facts, component, needed) do
    available = Facts.available_types(facts, component.id)

    for {id, m} <- catalog.stage_manifests,
        m.phase == :process,
        produces_needed?(m, needed),
        is_nil(Facts.outcome(facts, id, component.id)),
        Facts.probe(facts, id, component.id) != :not_applicable,
        inputs_satisfied?(m, available),
        do: {id, component.id}
  end

  defp produces_needed?(%Manifest{outputs: outputs}, needed) do
    Enum.any?(outputs, fn %{type: type} -> MapSet.member?(needed, type) end)
  end

  # Backward closure: desired types plus every input type their process
  # producers transitively consume.
  defp needed_types(catalog, content_type) do
    catalog.classification_desired
    |> Map.get(content_type, [])
    |> MapSet.new()
    |> then(&expand_needed(catalog, &1))
  end

  defp expand_needed(catalog, needed) do
    more =
      needed
      |> Enum.flat_map(&producer_input_types(catalog, &1))
      |> MapSet.new()

    union = MapSet.union(needed, more)
    if MapSet.equal?(union, needed), do: needed, else: expand_needed(catalog, union)
  end

  defp producer_input_types(catalog, type) do
    for {_id, m} <- catalog.stage_manifests,
        m.phase == :process,
        Enum.any?(m.outputs, &(&1.type == type)),
        input <- m.inputs,
        do: input.type
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/cham/plan_test.exs`
Expected: PASS (all prior tests still green; 7 new process-frontier tests pass).

- [ ] **Step 5: Commit**

```bash
git add lib/cham/plan.ex test/cham/plan_test.exs
git commit -m "feat(v3): Cham.Plan per-component process frontier (backward DAG)"
```

---

## Task 7: conflict resolution (OR), determinism, and an end-to-end walk

**Files:**
- Modify: `lib/cham/plan.ex` (replace `produces_needed?/2` usage with `wants_output?/4` in `component_frontier/4`)
- Test: `test/cham/plan_test.exs` (add a `conflict resolution & determinism` describe block)

**Process-phase OR resolution (§6, "first success wins"):** competing process producers declare the *same* output type; once one has produced it, the others must drop out. We get this by admitting a process producer only if it has a *needed* output that is **not yet produced** for the component. Independent producers (different outputs) are unaffected — that is the AND case, which already fans out.

**Scope note (deliberate Phase 2 limitation):** OR resolution for *competing extract producers* (two extractors of the same content_type) is **not** implemented here. Same-output extract competition collides with the deferred "multiple same-type components" question (spec §11 / reconciliation Part E, blocked by `unique(snapshot_id, content_type)`). Extract remains eager fan-out of independent producers; capture OR is the ordered candidate walk. Revisit when a real competing-extractor case exists (YAGNI).

- [ ] **Step 1: Write the failing test (append to `test/cham/plan_test.exs`)**

`proc/3` comes from `Cham.PlanFixtures`. `extracted("article", "c1", "article_markdown")` (also from fixtures) builds an article snapshot with its `article_markdown` extracted.

```elixir
  describe "conflict resolution & determinism" do
    test "OR: a competing producer drops out once the shared output is produced" do
      cat =
        catalog(
          [
            manifest("passe_partout", phase: :bootstrap),
            proc("summarize_a", "article_markdown", "summary"),
            proc("summarize_b", "article_markdown", "summary")
          ],
          capture_order: ["passe_partout"],
          classification_desired: %{"article" => ["summary"]}
        )

      # Neither has run: both are eligible competitors (executor picks/dedups).
      assert Plan.plan(cat, extracted("article", "c1", "article_markdown")) ==
               {:run, [{"summarize_a", "c1"}, {"summarize_b", "c1"}]}

      # summarize_a produced "summary": summarize_b drops out, goal met => complete.
      f = extracted("article", "c1", "article_markdown") |> Map.update!(:outcomes, &(&1 ++ [produced("summarize_a", "c1", [{"summary", :derived}])]))
      assert Plan.plan(cat, f) == {:terminal, :complete}
    end

    test "AND: independent producers of different desired outputs both run" do
      cat =
        catalog(
          [
            manifest("passe_partout", phase: :bootstrap),
            proc("summarize", "article_markdown", "summary"),
            proc("auto_tag", "article_markdown", "tags")
          ],
          capture_order: ["passe_partout"],
          classification_desired: %{"article" => ["summary", "tags"]}
        )

      assert Plan.plan(cat, extracted("article", "c1", "article_markdown")) ==
               {:run, [{"auto_tag", "c1"}, {"summarize", "c1"}]}
    end

    test "decision is independent of stage_manifests insertion order" do
      stages = [
        manifest("passe_partout", phase: :bootstrap),
        proc("summarize", "article_markdown", "summary"),
        proc("auto_tag", "article_markdown", "tags")
      ]

      opts = [capture_order: ["passe_partout"], classification_desired: %{"article" => ["summary", "tags"]}]

      forward = catalog(stages, opts)
      reversed = catalog(Enum.reverse(stages), opts)

      assert Plan.plan(forward, extracted("article", "c1", "article_markdown")) == Plan.plan(reversed, extracted("article", "c1", "article_markdown"))
    end

    test "end-to-end: capture -> extract -> process -> complete" do
      cat =
        catalog(
          [
            manifest("passe_partout", phase: :bootstrap),
            manifest("extract_article", phase: :extract, inputs: [io("html_capture")], outputs: [io("article_markdown")]),
            proc("summarize", "article_markdown", "summary")
          ],
          capture_order: ["passe_partout"],
          classification_desired: %{"article" => ["summary"]}
        )

      # 1. Nothing yet -> run capture.
      assert Plan.plan(cat, facts()) == {:run, [{"passe_partout", nil}]}

      # 2. Captured -> fan out extraction.
      f2 = facts(outcomes: [produced("passe_partout", nil, [{"html_capture", :capture}])])
      assert Plan.plan(cat, f2) == {:run, [{"extract_article", nil}]}

      # 3. Extracted an article component -> process toward summary.
      f3 =
        facts(
          components: [%{id: "c1", content_type: "article"}],
          outcomes: [
            produced("passe_partout", nil, [{"html_capture", :capture}]),
            produced("extract_article", "c1", [{"article_markdown", :extracted}])
          ]
        )

      assert Plan.plan(cat, f3) == {:run, [{"summarize", "c1"}]}

      # 4. Summary produced -> complete.
      f4 = f3 |> Map.update!(:outcomes, &(&1 ++ [produced("summarize", "c1", [{"summary", :derived}])]))
      assert Plan.plan(cat, f4) == {:terminal, :complete}
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/cham/plan_test.exs`
Expected: FAIL on the OR test — `summarize_b` is still admitted after `summarize_a` produces `summary` (it returns `{:run, [{"summarize_b", "c1"}]}` instead of `{:terminal, :complete}`).

- [ ] **Step 3: Add `wants_output?/4` and use it in `component_frontier/4`**

In `lib/cham/plan.ex`, in `component_frontier/4` replace:

```elixir
        produces_needed?(m, needed),
```

with:

```elixir
        wants_output?(m, needed, facts, component.id),
```

Then replace `produces_needed?/2`:

```elixir
  defp produces_needed?(%Manifest{outputs: outputs}, needed) do
    Enum.any?(outputs, fn %{type: type} -> MapSet.member?(needed, type) end)
  end
```

with:

```elixir
  # Wanted iff the stage produces a needed type that is not yet produced for the
  # component. The "not yet produced" clause gives OR resolution: once a
  # competing producer has emitted the shared output, the others drop out (§6).
  defp wants_output?(%Manifest{outputs: outputs}, needed, facts, component_id) do
    Enum.any?(outputs, fn %{type: type} ->
      MapSet.member?(needed, type) and not Facts.produced?(facts, type, component_id)
    end)
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/cham/plan_test.exs`
Expected: PASS (all describe blocks green).

- [ ] **Step 5: Run the full quality gate**

Run: `just check`
Expected: exit 0 — `mix format --check-formatted`, compile (warnings-as-errors), `credo --strict`, `sobelow`, `dialyzer`, and `mix test` all pass. (`Cham.Plan` is pure with full typespecs, so dialyzer should be clean. If `mix format` reports diffs, run `mix format` and re-stage.)

- [ ] **Step 6: Commit**

```bash
git add lib/cham/plan.ex test/cham/plan_test.exs
git commit -m "feat(v3): Cham.Plan process-phase OR resolution + determinism coverage"
```

---

## Done

After Task 7, `Cham.Plan.plan/2` implements the full Phase 2 spec: capture walk, extract fan-out, per-component process DAG, probe-first `{:query_can_process}`, terminal tiers, and process-phase OR resolution — all pure, with no Oban/DB/clock. The frozen seams `Catalog`/`Facts`/`Outcome` are ready for Phase 3 (projection) to populate and Phase 4 (executor) to consume. `checkpoint.md` should be updated to mark Phase 2 done (kept uncommitted, as before).
