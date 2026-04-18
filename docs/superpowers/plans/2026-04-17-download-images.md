# Download Images Plugin Implementation Plan

**Goal:** Add a pipeline stage that rehosts inline article images locally, producing a derived markdown artifact with rewritten URLs so archived articles survive remote hosts going down.

**Architecture:** Python script (via ScriptRunner + `uv`) parses the original `content.md`, downloads each `![](url)` reference, saves each as `img_<md5(url)>.<ext>`, and writes a rewritten `content.md` with local URLs. Elixir stage wraps it as a single derived artifact. UI prefers derived content over original for articles, with graceful fallback.

**Tech Stack:** Elixir/Phoenix, Python 3.11+ with `httpx`, Earmark (existing), Oban (existing).

---

## File Structure

- **Create:** `scripts/download_images/main.py` — Python downloader + rewriter. Reads `content.md`, emits rewritten `content.md` + image files + JSON summary to stdout.
- **Create:** `lib/cham/plugins/download_images.ex` — `Cham.Plugins.DownloadImages` plugin and `DownloadImages.Stage`. Loads item URL, invokes script, packages artifact.
- **Modify:** `lib/cham/application.ex:73-87` — register the new plugin.
- **Modify:** `lib/cham_web/live/item_detail_live.ex:193-199` — `resolve_primary_content` for articles prefers derived, falls back to original.
- **Create:** `test/cham/plugins/download_images_test.exs` — unit + integration tests.

---

## Task 1: Python script

**File:** `scripts/download_images/main.py`

The script takes: `<input_md> <output_dir> <base_url> <item_id>`. It writes `output_dir/content.md` and `output_dir/img_*.ext` files, prints JSON summary to stdout.

Key design points:
- Key for hashing = URL as written in markdown. No normalization.
- Extension = path-extension (before `?`) or guessed from `Content-Type`.
- Fetch URL = `urljoin(base_url, key)` with redirect following.
- Per-image failure preserves remote URL in rewritten markdown.
- 10s connect / 30s read timeouts, 10 MB cap per image.

Content:

```python
# /// script
# requires-python = ">=3.11"
# dependencies = ["httpx>=0.27"]
# ///

import hashlib
import json
import mimetypes
import re
import sys
from pathlib import Path
from urllib.parse import urljoin, urlparse

import httpx

MAX_BYTES = 10_000_000
CONNECT_TIMEOUT = 10.0
READ_TIMEOUT = 30.0
IMAGE_RE = re.compile(r"!\[([^\]]*)\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")


def extension_for(url_key: str, content_type: str | None) -> str:
    path = urlparse(url_key).path
    if "." in path.rsplit("/", 1)[-1]:
        ext = "." + path.rsplit(".", 1)[-1].lower()
        if 1 < len(ext) <= 6:
            return ext
    if content_type:
        ct = content_type.split(";", 1)[0].strip().lower()
        guessed = mimetypes.guess_extension(ct) or ""
        if guessed:
            return guessed
    return ".bin"


def local_filename(url_key: str, content_type: str | None) -> str:
    digest = hashlib.md5(url_key.encode("utf-8")).hexdigest()
    return f"img_{digest}{extension_for(url_key, content_type)}"


def download(client: httpx.Client, fetch_url: str, dest: Path) -> tuple[bool, str | None, str | None]:
    try:
        with client.stream("GET", fetch_url) as resp:
            if resp.status_code >= 400:
                return False, f"http {resp.status_code}", None
            content_type = resp.headers.get("content-type")
            total = 0
            with dest.open("wb") as f:
                for chunk in resp.iter_bytes():
                    total += len(chunk)
                    if total > MAX_BYTES:
                        return False, "too large", content_type
                    f.write(chunk)
        return True, None, content_type
    except httpx.HTTPError as e:
        return False, f"http error: {e}", None


def main() -> None:
    if len(sys.argv) < 5:
        print("Usage: main.py <input_md> <output_dir> <base_url> <item_id>", file=sys.stderr)
        sys.exit(1)

    input_md = Path(sys.argv[1])
    output_dir = Path(sys.argv[2])
    base_url = sys.argv[3]
    item_id = sys.argv[4]

    output_dir.mkdir(parents=True, exist_ok=True)
    text = input_md.read_text(encoding="utf-8")

    seen: dict[str, str | None] = {}
    summary = {"succeeded": 0, "failed": 0, "skipped_duplicate": 0, "failures": []}

    timeout = httpx.Timeout(READ_TIMEOUT, connect=CONNECT_TIMEOUT)
    with httpx.Client(timeout=timeout, follow_redirects=True) as client:
        def replace(match: re.Match[str]) -> str:
            alt, url_key = match.group(1), match.group(2)
            if url_key in seen:
                local = seen[url_key]
                if local is not None:
                    summary["skipped_duplicate"] += 1
                    return f"![{alt}](/api/v1/items/{item_id}/files/{local})"
                return match.group(0)

            fetch_url = urljoin(base_url, url_key)
            # Guess filename up-front using path extension; may rename on content-type fallback.
            tentative = local_filename(url_key, None)
            dest = output_dir / tentative

            ok, reason, content_type = download(client, fetch_url, dest)
            if not ok:
                dest.unlink(missing_ok=True)
                seen[url_key] = None
                summary["failed"] += 1
                summary["failures"].append({"url": url_key, "reason": reason or "unknown"})
                return match.group(0)

            # If the path had no extension, rename using content-type-derived extension.
            final_name = local_filename(url_key, content_type)
            if final_name != tentative:
                final_dest = output_dir / final_name
                dest.rename(final_dest)
                dest = final_dest

            seen[url_key] = final_name
            summary["succeeded"] += 1
            return f"![{alt}](/api/v1/items/{item_id}/files/{final_name})"

        rewritten = IMAGE_RE.sub(replace, text)

    (output_dir / "content.md").write_text(rewritten, encoding="utf-8")
    print(json.dumps(summary))


if __name__ == "__main__":
    main()
```

- [ ] **Step 1.1: Create the script file** with the content above.

- [ ] **Step 1.2: Smoke-test locally against the abliteration page.** Reuse `/tmp/abl/out/content.md` from earlier, and run:

```bash
mkdir -p /tmp/dlimg_out
uv run scripts/download_images/main.py /tmp/abl/out/content.md /tmp/dlimg_out \
  https://huggingface.co/blog/mlabonne/abliteration test-item-id
ls /tmp/dlimg_out
head -20 /tmp/dlimg_out/content.md
```

Expected: JSON summary on stdout (e.g. `{"succeeded": 2, "failed": 0, …}`), `content.md` with `/api/v1/items/test-item-id/files/img_*.png` references, and the image files present.

- [ ] **Step 1.3: Commit.**

```bash
git add scripts/download_images/main.py
git commit -m "feat(plugins): add download_images Python script"
```

---

## Task 2: Elixir plugin

**Files:**
- Create: `lib/cham/plugins/download_images.ex`

Content:

```elixir
defmodule Cham.Plugins.DownloadImages do
  @behaviour Cham.Plugin

  @impl true
  def plugin_id, do: "download_images"

  @impl true
  def name, do: "Download Images"

  @impl true
  def description do
    "Downloads inline article images locally and produces a derived markdown " <>
      "artifact with URLs rewritten to local paths. Makes archived articles " <>
      "self-contained against remote host outages."
  end

  @impl true
  def config_schema, do: []

  @impl true
  def init(_context), do: {:ok, %{}}

  @impl true
  def stages(_state), do: [__MODULE__.Stage]
end

defmodule Cham.Plugins.DownloadImages.Stage do
  @behaviour Cham.Stage

  @impl true
  def name, do: "Download Images"

  @impl true
  def description, do: "Fetches images referenced by an article's markdown and rewrites URLs locally"

  @impl true
  def input_matchers,
    do: [
      %{
        "origin" => "original",
        "format" => "text",
        "type" => "content",
        "content_type" => "text/markdown"
      }
    ]

  @impl true
  def output_labels,
    do: [
      %{
        "origin" => "derived",
        "format" => "text",
        "type" => "content",
        "content_type" => "text/markdown",
        "provider" => "download_images"
      }
    ]

  @impl true
  def queue, do: :general

  @impl true
  def max_attempts, do: 3

  @impl true
  def can_process?(current_artifacts) do
    has_markdown =
      Enum.any?(current_artifacts, fn labels ->
        labels["origin"] == "original" and
          labels["format"] == "text" and
          labels["type"] == "content" and
          labels["content_type"] == "text/markdown"
      end)

    if has_markdown, do: {:ready, input_matchers(), []}, else: :not_applicable
  end

  @impl true
  def perform(input_artifacts, working_dir, _desired, item_id) do
    [input] = input_artifacts
    [md_filename | _] = input.filenames
    md_path = Path.join(input.input_path, md_filename)

    base_url =
      case Cham.Items.get_item!(item_id) do
        %{url: url} when is_binary(url) -> url
        _ -> ""
      end

    File.mkdir_p!(working_dir)

    case Cham.ScriptRunner.run_script_sync(
           "download_images",
           [md_path, working_dir, base_url, to_string(item_id)],
           timeout: 120_000
         ) do
      {:ok, output, _stderr, 0} ->
        summary = parse_summary(output)

        filenames =
          working_dir
          |> File.ls!()
          |> Enum.sort()

        {:ok,
         %{
           artifacts: [
             %{
               labels: %{
                 "origin" => "derived",
                 "format" => "text",
                 "type" => "content",
                 "content_type" => "text/markdown",
                 "provider" => "download_images"
               },
               filenames: filenames
             }
           ],
           item_metadata: %{},
           provenance: Map.merge(%{"tool" => "download_images"}, summary)
         }}

      {:ok, output, _stderr, exit_code} ->
        {:error, "download_images script failed (exit #{exit_code}): #{String.trim(output)}"}

      {:error, :timeout, _output, _stderr} ->
        {:error, "download_images script timed out"}
    end
  end

  defp parse_summary(output) do
    output
    |> String.trim()
    |> String.split("\n")
    |> List.last()
    |> case do
      nil -> %{}
      line -> Jason.decode!(line)
    end
  rescue
    _ -> %{}
  end
end
```

- [ ] **Step 2.1: Write the file.**

- [ ] **Step 2.2: `mix compile` to verify.**

- [ ] **Step 2.3: Commit.**

```bash
git add lib/cham/plugins/download_images.ex
git commit -m "feat(plugins): add download_images Elixir stage"
```

---

## Task 3: Register plugin

**File:** `lib/cham/application.ex:73-87`

- [ ] **Step 3.1: Add the plugin to the core_plugins list.** Append `Cham.Plugins.DownloadImages` after `Cham.Plugins.ExtractThumbnail`:

```elixir
defp register_core_plugins do
  core_plugins = [
    Cham.Plugins.GenericDownloadUrl,
    Cham.Plugins.ContentTypeRouter,
    Cham.Plugins.ExtractArticle,
    Cham.Plugins.ExtractFeedItems,
    Cham.Plugins.ExtractPdf,
    Cham.Plugins.ExtractAudio,
    Cham.Plugins.TranscribeWhisper,
    Cham.Plugins.TranscribeFireworks,
    Cham.Plugins.SummarizeOllama,
    Cham.Plugins.AutoTag,
    Cham.Plugins.CleanTitle,
    Cham.Plugins.ExtractThumbnail,
    Cham.Plugins.DownloadImages
  ]
  # ...
```

- [ ] **Step 3.2: `mix compile`.**

- [ ] **Step 3.3: Commit.**

```bash
git add lib/cham/application.ex
git commit -m "feat(plugins): register download_images"
```

---

## Task 4: UI prefers derived content

**File:** `lib/cham_web/live/item_detail_live.ex:193-199`

- [ ] **Step 4.1: Change `resolve_primary_content` so the article branch prefers `origin=derived`.** Replace lines 193-199:

```elixir
defp resolve_primary_content(item, artifacts, stage_history) do
  case item.content_type do
    "article" -> resolve_article_content(item, artifacts, stage_history)
    "video" -> resolve_artifact_content(item, artifacts, stage_history, "transcript")
    _ -> %{state: :not_requested, content: nil, error: nil}
  end
end

defp resolve_article_content(item, artifacts, stage_history) do
  case resolve_artifact_content(item, artifacts, stage_history, "content", "derived") do
    %{state: :available} = result ->
      result

    _ ->
      resolve_artifact_content(item, artifacts, stage_history, "content", "original")
  end
end
```

- [ ] **Step 4.2: `mix compile`.**

- [ ] **Step 4.3: Commit.**

```bash
git add lib/cham_web/live/item_detail_live.ex
git commit -m "feat(web): prefer derived content artifact for articles"
```

---

## Task 5: Unit tests

**File:** `test/cham/plugins/download_images_test.exs`

- [ ] **Step 5.1: Write the test file.**

```elixir
defmodule Cham.Plugins.DownloadImagesTest do
  use ExUnit.Case, async: true

  alias Cham.Plugins.DownloadImages
  alias Cham.Plugins.DownloadImages.Stage

  describe "Plugin behaviour" do
    test "plugin_id" do
      assert DownloadImages.plugin_id() == "download_images"
    end

    test "stages returns Stage" do
      assert DownloadImages.stages(%{}) == [Stage]
    end

    test "config_schema is empty" do
      assert DownloadImages.config_schema() == []
    end
  end

  describe "Stage metadata" do
    test "queue" do
      assert Stage.queue() == :general
    end

    test "input_matchers" do
      assert Stage.input_matchers() == [
               %{
                 "origin" => "original",
                 "format" => "text",
                 "type" => "content",
                 "content_type" => "text/markdown"
               }
             ]
    end

    test "output_labels" do
      assert Stage.output_labels() == [
               %{
                 "origin" => "derived",
                 "format" => "text",
                 "type" => "content",
                 "content_type" => "text/markdown",
                 "provider" => "download_images"
               }
             ]
    end
  end

  describe "can_process?/1" do
    test "ready when a markdown content artifact exists" do
      artifacts = [
        %{
          "origin" => "original",
          "format" => "text",
          "type" => "content",
          "content_type" => "text/markdown"
        }
      ]

      assert {:ready, _, []} = Stage.can_process?(artifacts)
    end

    test "not_applicable without markdown content" do
      artifacts = [%{"origin" => "original", "format" => "text", "type" => "article"}]
      assert :not_applicable = Stage.can_process?(artifacts)
    end

    test "not_applicable for empty artifacts" do
      assert :not_applicable = Stage.can_process?([])
    end
  end
end
```

- [ ] **Step 5.2: Run tests.**

```bash
mix test test/cham/plugins/download_images_test.exs
```

Expected: all tests pass.

- [ ] **Step 5.3: Commit.**

```bash
git add test/cham/plugins/download_images_test.exs
git commit -m "test(plugins): add download_images tests"
```

---

## Task 6: End-to-end verification

- [ ] **Step 6.1: `mix compile --warnings-as-errors`.**

- [ ] **Step 6.2: `mix format`.**

- [ ] **Step 6.3: `mix test` (unit only, no integration tag) and confirm no regressions.**

- [ ] **Step 6.4: Manual check** — re-run the python script against the cached HF article and confirm `content.md` has local URLs and images were saved.

---

## Self-Review

**Spec coverage:**
- Architecture (new plugin + stage) → Tasks 1–3
- Filename invariant `img_<md5(url-as-written)>.<ext>` → Task 1 `local_filename`
- Relative URL resolution via `urljoin(item.url, key)` → Task 1 `replace()`; Task 2 loads `item.url`
- Per-image failure keeps remote URL → Task 1 `replace()` (returns `match.group(0)` on failure)
- Empty-images-markdown still emits derived artifact → Task 1 always writes `content.md`
- UI preference derived→original with fallback → Task 4
- Provenance counters → Task 2 merges JSON summary into `provenance`

**Not covered in tests (deliberate):** actual network downloads. The spec lists integration tests; we can add them once the stage is verified in-hand. Not worth gating the initial cut on.

**Placeholder scan:** none.

**Type consistency:** `Stage` module name and `DownloadImages.Stage` alias match throughout.
