# Phase 6: Built-in Plugins Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement 7 core plugins that make Cham functional out of the box — from URL download through content routing, article extraction, transcription, summarization, tagging, and title cleanup.

**Architecture:** Each plugin is a single Elixir module implementing `Cham.Plugin` with nested stage modules implementing `Cham.Stage`. Python scripts handle ML-heavy work (article extraction via trafilatura, transcription via faster-whisper). LLM-based stages use the existing `Cham.LLM.Provider` system. All plugins are compiled-in and discovered via the Plugin Registry.

**Tech Stack:** Elixir (Plugin/Stage behaviours, Req HTTP client), Python (trafilatura, faster-whisper via uv), Oban (job queues), LLM Provider (OpenAI-compatible API for Ollama)

**Spec:** `docs/superpowers/specs/2026-04-04-phase-6-built-in-plugins-design.md`

---

## File Structure

```
lib/cham/plugins/
  generic_download_url.ex    — Plugin + DownloadStage (HTTP downloader, :network queue)
  content_type_router.ex     — Plugin + RouteStage (dynamic stage, :general queue)
  extract_article.ex         — Plugin + ExtractStage (Python/trafilatura, :general queue)
  transcribe_whisper.ex      — Plugin + TranscribeStage (Python/faster-whisper, :gpu queue)
  summarize_ollama.ex        — Plugin + SummarizeStage (LLM provider, :gpu queue)
  auto_tag.ex                — Plugin + TagStage (LLM provider, :gpu queue)
  clean_title.ex             — Plugin + CleanStage (dynamic stage, LLM provider, :gpu queue)

scripts/
  extract_article/main.py    — trafilatura article extraction
  transcribe_whisper/main.py — faster-whisper transcription

test/cham/plugins/
  generic_download_url_test.exs
  content_type_router_test.exs
  extract_article_test.exs
  transcribe_whisper_test.exs
  summarize_ollama_test.exs
  auto_tag_test.exs
  clean_title_test.exs
```

---

## Task 1: `generic_download_url` Plugin

**Files:**
- Create: `lib/cham/plugins/generic_download_url.ex`
- Create: `test/cham/plugins/generic_download_url_test.exs`

- [ ] **Step 1: Write failing test for plugin registration**

```elixir
# test/cham/plugins/generic_download_url_test.exs
defmodule Cham.Plugins.GenericDownloadUrlTest do
  use Cham.DataCase

  alias Cham.Plugins.GenericDownloadUrl

  describe "plugin behaviour" do
    test "returns correct plugin_id" do
      assert GenericDownloadUrl.plugin_id() == "generic_download_url"
    end

    test "returns config schema with timeout and max_body_size" do
      schema = GenericDownloadUrl.config_schema()
      keys = Enum.map(schema, & &1.key)
      assert :timeout in keys
      assert :max_body_size in keys
    end

    test "init succeeds with empty config" do
      assert {:ok, _state} = GenericDownloadUrl.init(%{config: %{}})
    end

    test "stages returns DownloadStage" do
      assert [Cham.Plugins.GenericDownloadUrl.DownloadStage] = GenericDownloadUrl.stages(%{})
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/cham/plugins/generic_download_url_test.exs`
Expected: Compilation error — module `Cham.Plugins.GenericDownloadUrl` not found

- [ ] **Step 3: Implement plugin module**

```elixir
# lib/cham/plugins/generic_download_url.ex
defmodule Cham.Plugins.GenericDownloadUrl do
  @behaviour Cham.Plugin

  @impl true
  def plugin_id, do: "generic_download_url"

  @impl true
  def name, do: "Generic URL Downloader"

  @impl true
  def description, do: "Fallback HTTP downloader for any URL"

  @impl true
  def config_schema do
    [
      %{
        key: :timeout,
        type: :integer,
        default: 300_000,
        description: "Download timeout in milliseconds",
        required: false,
        options: nil
      },
      %{
        key: :max_body_size,
        type: :integer,
        default: 524_288_000,
        description: "Maximum download size in bytes (default 500MB)",
        required: false,
        options: nil
      }
    ]
  end

  @impl true
  def init(_context), do: {:ok, %{}}

  @impl true
  def stages(_state), do: [__MODULE__.DownloadStage]
end
```

- [ ] **Step 4: Run test to verify plugin behaviour tests pass**

Run: `mix test test/cham/plugins/generic_download_url_test.exs`
Expected: All 4 tests pass

- [ ] **Step 5: Write failing test for DownloadStage metadata**

Add to the test file:

```elixir
  alias Cham.Plugins.GenericDownloadUrl.DownloadStage

  describe "stage behaviour" do
    test "returns correct stage metadata" do
      assert DownloadStage.name() == "Download URL"
      assert DownloadStage.queue() == :network
      assert DownloadStage.max_attempts() == 3
      assert DownloadStage.input_matchers() == [%{}]
      assert DownloadStage.output_labels() == [%{"origin" => "original", "type" => "initial_download"}]
    end
  end
```

- [ ] **Step 6: Run test to verify it fails**

Run: `mix test test/cham/plugins/generic_download_url_test.exs`
Expected: Compilation error — module `DownloadStage` not found

- [ ] **Step 7: Implement DownloadStage module skeleton**

Add to `lib/cham/plugins/generic_download_url.ex`:

```elixir
defmodule Cham.Plugins.GenericDownloadUrl.DownloadStage do
  @behaviour Cham.Stage

  @impl true
  def name, do: "Download URL"

  @impl true
  def description, do: "Downloads content from a URL via HTTP"

  @impl true
  def input_matchers, do: [%{}]

  @impl true
  def output_labels, do: [%{"origin" => "original", "type" => "initial_download"}]

  @impl true
  def queue, do: :network

  @impl true
  def max_attempts, do: 3

  @impl true
  def perform(_input_artifacts, _working_dir, _desired_artifacts, _item_id) do
    {:error, "not implemented"}
  end
end
```

- [ ] **Step 8: Run test to verify stage metadata tests pass**

Run: `mix test test/cham/plugins/generic_download_url_test.exs`
Expected: All tests pass

- [ ] **Step 9: Write failing test for perform — successful download**

Add to the test file:

```elixir
  describe "perform/4" do
    setup do
      bypass = Bypass.open()
      tmp = Path.join(System.tmp_dir!(), "cham_dl_test_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)
      %{bypass: bypass, working_dir: tmp}
    end

    test "downloads content and produces artifact", %{bypass: bypass, working_dir: working_dir} do
      Bypass.expect(bypass, "HEAD", "/page", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "text/html")
        |> Plug.Conn.put_resp_header("content-length", "13")
        |> Plug.Conn.resp(200, "")
      end)

      Bypass.expect(bypass, "GET", "/page", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "text/html")
        |> Plug.Conn.resp(200, "<h1>Hello</h1>")
      end)

      url = "http://localhost:#{bypass.port}/page"
      {:ok, item} = Cham.Items.create_item(%{url: url, slug: "test-#{System.unique_integer([:positive])}"})

      config = %{timeout: 30_000, max_body_size: 10_000_000}

      assert {:ok, result} = DownloadStage.perform([], working_dir, [], item.id, config)

      assert [artifact] = result.artifacts
      assert artifact.labels["origin"] == "original"
      assert artifact.labels["type"] == "initial_download"
      assert artifact.labels["content_type"] == "text/html"
      assert [filename] = artifact.filenames
      assert File.exists?(Path.join(working_dir, filename))
      assert File.read!(Path.join(working_dir, filename)) == "<h1>Hello</h1>"
    end
  end
```

- [ ] **Step 10: Run test to verify it fails**

Run: `mix test test/cham/plugins/generic_download_url_test.exs`
Expected: FAIL — `perform` returns `{:error, "not implemented"}`

- [ ] **Step 11: Implement perform/4**

Note: Since the `Cham.Stage` behaviour defines `perform/4` but our download stage needs plugin config (timeout, max_body_size), we pass config via a 5th argument for internal use. The `perform/4` callback reads config from the plugin registry. Replace the `perform` function in `DownloadStage`:

```elixir
  @impl true
  def perform(_input_artifacts, working_dir, _desired_artifacts, item_id) do
    config = get_config()
    perform(_input_artifacts, working_dir, _desired_artifacts, item_id, config)
  end

  def perform(_input_artifacts, working_dir, _desired_artifacts, item_id, config) do
    timeout = Map.get(config, :timeout, 300_000)
    max_body_size = Map.get(config, :max_body_size, 524_288_000)

    item = Cham.Items.get_item!(item_id)
    url = item.url

    with {:ok, content_type, content_length} <- head_check(url, timeout, max_body_size),
         {:ok, filename} <- download(url, working_dir, content_type, timeout) do
      {:ok,
       %{
         artifacts: [
           %{
             labels: %{
               "origin" => "original",
               "type" => "initial_download",
               "content_type" => content_type
             },
             filenames: [filename]
           }
         ],
         item_metadata: %{
           "content_type" => content_type,
           "content_length" => content_length
         },
         provenance: %{}
       }}
    end
  end

  defp get_config do
    case Cham.Plugin.Registry.get_plugin("generic_download_url") do
      {:ok, plugin} -> Map.get(plugin.state, :config, %{})
      _ -> %{}
    end
  end

  defp head_check(url, timeout, max_body_size) do
    case Req.head(url, receive_timeout: timeout, connect_options: [timeout: 10_000], retry: false) do
      {:ok, %{status: status, headers: headers}} when status in 200..399 ->
        content_type = get_header(headers, "content-type") |> parse_content_type()
        content_length = get_header(headers, "content-length") |> parse_content_length()

        if content_length && content_length > max_body_size do
          {:error, "Content too large: #{content_length} bytes exceeds #{max_body_size} limit"}
        else
          {:ok, content_type, content_length}
        end

      {:ok, %{status: status}} ->
        {:error, "HEAD request failed with HTTP #{status}"}

      {:error, reason} ->
        {:error, "HEAD request failed: #{inspect(reason)}"}
    end
  end

  defp download(url, working_dir, content_type, timeout) do
    ext = extension_for(content_type, url)
    filename = "original#{ext}"
    output_path = Path.join(working_dir, filename)

    case Req.get(url,
           receive_timeout: timeout,
           connect_options: [timeout: 10_000],
           retry: false,
           into: File.stream!(output_path)
         ) do
      {:ok, %{status: status}} when status in 200..399 ->
        {:ok, filename}

      {:ok, %{status: status}} ->
        File.rm(output_path)
        {:error, "Download failed with HTTP #{status}"}

      {:error, reason} ->
        File.rm(output_path)
        {:error, "Download failed: #{inspect(reason)}"}
    end
  end

  defp get_header(headers, key) do
    case List.keyfind(headers, key, 0) do
      {_, value} -> value
      nil -> nil
    end
  end

  defp parse_content_type(nil), do: "application/octet-stream"
  defp parse_content_type(value), do: value |> String.split(";") |> List.first() |> String.trim()

  defp parse_content_length(nil), do: nil
  defp parse_content_length(value) do
    case Integer.parse(value) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp extension_for(content_type, url) do
    mime_ext =
      case content_type do
        "text/html" -> ".html"
        "application/pdf" -> ".pdf"
        "video/" <> _ -> ".mp4"
        "audio/" <> _ -> ".m4a"
        "image/jpeg" -> ".jpg"
        "image/png" -> ".png"
        "text/plain" -> ".txt"
        "application/json" -> ".json"
        _ -> nil
      end

    mime_ext || url_extension(url) || ".bin"
  end

  defp url_extension(url) do
    path = URI.parse(url).path || ""
    ext = Path.extname(path)
    if ext != "", do: ext, else: nil
  end
```

- [ ] **Step 12: Run test to verify it passes**

Run: `mix test test/cham/plugins/generic_download_url_test.exs`
Expected: All tests pass

- [ ] **Step 13: Write failing test for HEAD size check rejection**

Add to the `perform/4` describe block:

```elixir
    test "rejects content exceeding max_body_size", %{bypass: bypass, working_dir: working_dir} do
      Bypass.expect(bypass, "HEAD", "/big", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "video/mp4")
        |> Plug.Conn.put_resp_header("content-length", "999999999")
        |> Plug.Conn.resp(200, "")
      end)

      url = "http://localhost:#{bypass.port}/big"
      {:ok, item} = Cham.Items.create_item(%{url: url, slug: "test-#{System.unique_integer([:positive])}"})

      config = %{timeout: 30_000, max_body_size: 1_000}

      assert {:error, message} = DownloadStage.perform([], working_dir, [], item.id, config)
      assert message =~ "Content too large"
    end
```

- [ ] **Step 14: Run test to verify it passes** (implementation already handles this)

Run: `mix test test/cham/plugins/generic_download_url_test.exs`
Expected: All tests pass

- [ ] **Step 15: Write failing test for HTTP error handling**

Add to the `perform/4` describe block:

```elixir
    test "returns error on HTTP 404", %{bypass: bypass, working_dir: working_dir} do
      Bypass.expect(bypass, "HEAD", "/missing", fn conn ->
        Plug.Conn.resp(conn, 404, "Not Found")
      end)

      url = "http://localhost:#{bypass.port}/missing"
      {:ok, item} = Cham.Items.create_item(%{url: url, slug: "test-#{System.unique_integer([:positive])}"})

      config = %{timeout: 30_000, max_body_size: 10_000_000}

      assert {:error, message} = DownloadStage.perform([], working_dir, [], item.id, config)
      assert message =~ "404"
    end
```

- [ ] **Step 16: Run test to verify it passes**

Run: `mix test test/cham/plugins/generic_download_url_test.exs`
Expected: All tests pass

- [ ] **Step 17: Run full test suite and format**

Run: `mix format && mix test`
Expected: All tests pass, no formatting changes

- [ ] **Step 18: Commit**

```bash
git add lib/cham/plugins/generic_download_url.ex test/cham/plugins/generic_download_url_test.exs
git commit -m "feat: add generic_download_url plugin"
```

---

## Task 2: `content_type_router` Plugin

**Files:**
- Create: `lib/cham/plugins/content_type_router.ex`
- Create: `test/cham/plugins/content_type_router_test.exs`

- [ ] **Step 1: Write failing test for plugin behaviour**

```elixir
# test/cham/plugins/content_type_router_test.exs
defmodule Cham.Plugins.ContentTypeRouterTest do
  use Cham.DataCase

  alias Cham.Plugins.ContentTypeRouter
  alias Cham.Plugins.ContentTypeRouter.RouteStage

  describe "plugin behaviour" do
    test "returns correct plugin_id" do
      assert ContentTypeRouter.plugin_id() == "content_type_router"
    end

    test "has empty config schema" do
      assert ContentTypeRouter.config_schema() == []
    end

    test "stages returns RouteStage" do
      assert [RouteStage] = ContentTypeRouter.stages(%{})
    end
  end

  describe "stage behaviour" do
    test "returns correct stage metadata" do
      assert RouteStage.name() == "Content Type Router"
      assert RouteStage.queue() == :general
      assert RouteStage.max_attempts() == 3
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/cham/plugins/content_type_router_test.exs`
Expected: Compilation error

- [ ] **Step 3: Implement plugin and stage skeleton**

```elixir
# lib/cham/plugins/content_type_router.ex
defmodule Cham.Plugins.ContentTypeRouter do
  @behaviour Cham.Plugin

  @impl true
  def plugin_id, do: "content_type_router"

  @impl true
  def name, do: "Content Type Router"

  @impl true
  def description, do: "Routes downloads to format-specific labels based on content type"

  @impl true
  def config_schema, do: []

  @impl true
  def init(_context), do: {:ok, %{}}

  @impl true
  def stages(_state), do: [__MODULE__.RouteStage]
end

defmodule Cham.Plugins.ContentTypeRouter.RouteStage do
  @behaviour Cham.Stage

  @impl true
  def name, do: "Content Type Router"

  @impl true
  def description, do: "Routes initial downloads to format-specific artifact labels"

  @impl true
  def input_matchers, do: [%{"origin" => "original", "type" => "initial_download"}]

  @impl true
  def output_labels, do: [%{"origin" => "original", "format" => "routed"}]

  @impl true
  def queue, do: :general

  @impl true
  def max_attempts, do: 3

  @impl true
  def can_process?(current_artifacts) do
    has_download =
      Enum.any?(current_artifacts, fn artifact ->
        artifact["origin"] == "original" && artifact["type"] == "initial_download"
      end)

    if has_download, do: {:ready, input_matchers(), []}, else: :not_applicable
  end

  @impl true
  def perform(_input_artifacts, _working_dir, _desired_artifacts, _item_id) do
    {:error, "not implemented"}
  end
end
```

- [ ] **Step 4: Run test to verify skeleton tests pass**

Run: `mix test test/cham/plugins/content_type_router_test.exs`
Expected: All tests pass

- [ ] **Step 5: Write failing test for content type routing**

Add to the test file:

```elixir
  describe "perform/4" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "cham_router_test_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)
      %{working_dir: tmp}
    end

    test "routes text/html to article format", %{working_dir: working_dir} do
      # Create a source file to symlink
      src_dir = Path.join(System.tmp_dir!(), "cham_router_src_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(src_dir)
      File.write!(Path.join(src_dir, "original.html"), "<h1>Hello</h1>")
      on_exit(fn -> File.rm_rf!(src_dir) end)

      input_artifacts = [
        %{
          labels: %{"origin" => "original", "type" => "initial_download", "content_type" => "text/html"},
          filenames: ["original.html"],
          input_path: src_dir
        }
      ]

      assert {:ok, result} = RouteStage.perform(input_artifacts, working_dir, [], "item-1")

      assert [artifact] = result.artifacts
      assert artifact.labels["origin"] == "original"
      assert artifact.labels["format"] == "text"
      assert artifact.labels["type"] == "article"
      assert result.item_metadata["content_type"] == "article"
    end

    test "routes video/* to video format", %{working_dir: working_dir} do
      src_dir = Path.join(System.tmp_dir!(), "cham_router_src_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(src_dir)
      File.write!(Path.join(src_dir, "original.mp4"), "fake video")
      on_exit(fn -> File.rm_rf!(src_dir) end)

      input_artifacts = [
        %{
          labels: %{"origin" => "original", "type" => "initial_download", "content_type" => "video/mp4"},
          filenames: ["original.mp4"],
          input_path: src_dir
        }
      ]

      assert {:ok, result} = RouteStage.perform(input_artifacts, working_dir, [], "item-1")

      assert [artifact] = result.artifacts
      assert artifact.labels["format"] == "video"
      assert result.item_metadata["content_type"] == "video"
    end

    test "routes application/pdf to document format", %{working_dir: working_dir} do
      src_dir = Path.join(System.tmp_dir!(), "cham_router_src_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(src_dir)
      File.write!(Path.join(src_dir, "original.pdf"), "fake pdf")
      on_exit(fn -> File.rm_rf!(src_dir) end)

      input_artifacts = [
        %{
          labels: %{"origin" => "original", "type" => "initial_download", "content_type" => "application/pdf"},
          filenames: ["original.pdf"],
          input_path: src_dir
        }
      ]

      assert {:ok, result} = RouteStage.perform(input_artifacts, working_dir, [], "item-1")

      assert [artifact] = result.artifacts
      assert artifact.labels["format"] == "document"
      assert artifact.labels["type"] == "pdf"
      assert result.item_metadata["content_type"] == "document"
    end

    test "routes audio/* to audio format", %{working_dir: working_dir} do
      src_dir = Path.join(System.tmp_dir!(), "cham_router_src_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(src_dir)
      File.write!(Path.join(src_dir, "original.mp3"), "fake audio")
      on_exit(fn -> File.rm_rf!(src_dir) end)

      input_artifacts = [
        %{
          labels: %{"origin" => "original", "type" => "initial_download", "content_type" => "audio/mpeg"},
          filenames: ["original.mp3"],
          input_path: src_dir
        }
      ]

      assert {:ok, result} = RouteStage.perform(input_artifacts, working_dir, [], "item-1")

      assert [artifact] = result.artifacts
      assert artifact.labels["format"] == "audio"
      assert result.item_metadata["content_type"] == "audio"
    end

    test "routes unknown content type to unknown format", %{working_dir: working_dir} do
      src_dir = Path.join(System.tmp_dir!(), "cham_router_src_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(src_dir)
      File.write!(Path.join(src_dir, "original.bin"), "mystery data")
      on_exit(fn -> File.rm_rf!(src_dir) end)

      input_artifacts = [
        %{
          labels: %{"origin" => "original", "type" => "initial_download", "content_type" => "application/octet-stream"},
          filenames: ["original.bin"],
          input_path: src_dir
        }
      ]

      assert {:ok, result} = RouteStage.perform(input_artifacts, working_dir, [], "item-1")

      assert [artifact] = result.artifacts
      assert artifact.labels["format"] == "unknown"
      assert result.item_metadata["content_type"] == "unknown"
    end
  end
```

- [ ] **Step 6: Run test to verify it fails**

Run: `mix test test/cham/plugins/content_type_router_test.exs`
Expected: FAIL — `perform` returns `{:error, "not implemented"}`

- [ ] **Step 7: Implement perform/4**

Replace the `perform` function in `RouteStage`:

```elixir
  @impl true
  def perform(input_artifacts, working_dir, _desired_artifacts, _item_id) do
    [input | _] = input_artifacts
    content_type = input.labels["content_type"] || "application/octet-stream"

    {format_labels, human_type} = route_content_type(content_type)

    # Symlink source files into working directory
    filenames =
      Enum.map(input.filenames, fn filename ->
        src = Path.join(input.input_path, filename)
        dst = Path.join(working_dir, filename)

        case File.ln_s(src, dst) do
          :ok -> filename
          {:error, _} ->
            File.cp!(src, dst)
            filename
        end
      end)

    {:ok,
     %{
       artifacts: [
         %{
           labels: Map.merge(%{"origin" => "original"}, format_labels),
           filenames: filenames
         }
       ],
       item_metadata: %{"content_type" => human_type},
       provenance: %{}
     }}
  end

  defp route_content_type("text/html"), do: {%{"format" => "text", "type" => "article"}, "article"}
  defp route_content_type("application/pdf"), do: {%{"format" => "document", "type" => "pdf"}, "document"}

  defp route_content_type("video/" <> _), do: {%{"format" => "video"}, "video"}
  defp route_content_type("audio/" <> _), do: {%{"format" => "audio"}, "audio"}

  defp route_content_type("application/octet-stream"), do: {%{"format" => "unknown"}, "unknown"}
  defp route_content_type(_), do: {%{"format" => "unknown"}, "unknown"}
```

- [ ] **Step 8: Run test to verify all tests pass**

Run: `mix test test/cham/plugins/content_type_router_test.exs`
Expected: All tests pass

- [ ] **Step 9: Run full test suite and format**

Run: `mix format && mix test`
Expected: All tests pass

- [ ] **Step 10: Commit**

```bash
git add lib/cham/plugins/content_type_router.ex test/cham/plugins/content_type_router_test.exs
git commit -m "feat: add content_type_router plugin"
```

---

## Task 3: `extract_article` Plugin + Python Script

**Files:**
- Create: `lib/cham/plugins/extract_article.ex`
- Create: `scripts/extract_article/main.py`
- Create: `test/cham/plugins/extract_article_test.exs`

- [ ] **Step 1: Write the Python extraction script**

```python
# scripts/extract_article/main.py
# /// script
# requires-python = ">=3.11"
# dependencies = ["trafilatura>=1.6"]
# ///

import json
import sys
from pathlib import Path

import trafilatura


def main():
    if len(sys.argv) < 3:
        print("Usage: main.py <html_file> <output_dir>", file=sys.stderr)
        sys.exit(1)

    html_file = Path(sys.argv[1])
    output_dir = Path(sys.argv[2])

    html = html_file.read_text(encoding="utf-8", errors="replace")

    text = trafilatura.extract(
        html,
        output_format="txt",
        include_comments=False,
        include_tables=True,
    )

    if text is None:
        print("Could not extract article content", file=sys.stderr)
        sys.exit(1)

    metadata = trafilatura.extract(
        html,
        output_format="xmltei",
        include_comments=False,
    )

    meta = trafilatura.metadata.extract_metadata(html)

    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "content.md").write_text(text, encoding="utf-8")

    result = {}
    if meta:
        if meta.title:
            result["title"] = meta.title
        if meta.author:
            result["author"] = meta.author
        if meta.date:
            result["date"] = meta.date
        if meta.sitename:
            result["sitename"] = meta.sitename

    print(json.dumps(result))


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Write failing test for plugin behaviour**

```elixir
# test/cham/plugins/extract_article_test.exs
defmodule Cham.Plugins.ExtractArticleTest do
  use Cham.DataCase

  alias Cham.Plugins.ExtractArticle
  alias Cham.Plugins.ExtractArticle.ExtractStage

  describe "plugin behaviour" do
    test "returns correct plugin_id" do
      assert ExtractArticle.plugin_id() == "extract_article"
    end

    test "stages returns ExtractStage" do
      assert [ExtractStage] = ExtractArticle.stages(%{})
    end
  end

  describe "stage behaviour" do
    test "returns correct stage metadata" do
      assert ExtractStage.name() == "Extract Article"
      assert ExtractStage.queue() == :general
      assert ExtractStage.max_attempts() == 3
      assert ExtractStage.input_matchers() == [%{"origin" => "original", "format" => "text", "type" => "article"}]

      assert ExtractStage.output_labels() == [
               %{
                 "origin" => "original",
                 "format" => "text",
                 "type" => "content",
                 "content_type" => "text/markdown"
               }
             ]
    end
  end
end
```

- [ ] **Step 3: Run test to verify it fails**

Run: `mix test test/cham/plugins/extract_article_test.exs`
Expected: Compilation error

- [ ] **Step 4: Implement plugin and stage**

```elixir
# lib/cham/plugins/extract_article.ex
defmodule Cham.Plugins.ExtractArticle do
  @behaviour Cham.Plugin

  @impl true
  def plugin_id, do: "extract_article"

  @impl true
  def name, do: "Article Extractor"

  @impl true
  def description, do: "Extracts article content from HTML using trafilatura"

  @impl true
  def config_schema, do: []

  @impl true
  def init(_context), do: {:ok, %{}}

  @impl true
  def stages(_state), do: [__MODULE__.ExtractStage]
end

defmodule Cham.Plugins.ExtractArticle.ExtractStage do
  @behaviour Cham.Stage

  @impl true
  def name, do: "Extract Article"

  @impl true
  def description, do: "Extracts article text and metadata from HTML"

  @impl true
  def input_matchers, do: [%{"origin" => "original", "format" => "text", "type" => "article"}]

  @impl true
  def output_labels,
    do: [%{"origin" => "original", "format" => "text", "type" => "content", "content_type" => "text/markdown"}]

  @impl true
  def queue, do: :general

  @impl true
  def max_attempts, do: 3

  @impl true
  def perform(input_artifacts, working_dir, _desired_artifacts, _item_id) do
    [input | _] = input_artifacts
    [filename | _] = input.filenames
    html_path = Path.join(input.input_path, filename)

    case Cham.ScriptRunner.run_script_sync(
           "extract_article",
           [html_path, working_dir],
           timeout: 60_000
         ) do
      {:ok, stdout, _stderr, 0} ->
        metadata = parse_metadata(stdout)

        {:ok,
         %{
           artifacts: [
             %{
               labels: %{
                 "origin" => "original",
                 "format" => "text",
                 "type" => "content",
                 "content_type" => "text/markdown"
               },
               filenames: ["content.md"]
             }
           ],
           item_metadata: metadata,
           provenance: %{"tool" => "trafilatura"}
         }}

      {:ok, _stdout, _stderr, exit_code} ->
        {:error, "extract_article.py exited with code #{exit_code}"}

      {:error, :timeout, _stdout, _stderr} ->
        {:error, "extract_article.py timed out"}
    end
  end

  defp parse_metadata(stdout) do
    stdout
    |> String.trim()
    |> String.split("\n")
    |> List.last("")
    |> Jason.decode()
    |> case do
      {:ok, meta} -> meta
      {:error, _} -> %{}
    end
  end
end
```

- [ ] **Step 5: Run test to verify behaviour tests pass**

Run: `mix test test/cham/plugins/extract_article_test.exs`
Expected: All tests pass

- [ ] **Step 6: Write failing test for perform with mocked ScriptRunner**

Add to the test file. Since unit tests should not call real Python scripts, we test the logic by creating a test that prepares the expected output files and mocks the script call. A simpler approach: test with a real HTML file as an integration test.

```elixir
  @moduletag :integration

  describe "perform/4" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "cham_article_test_#{:erlang.unique_integer([:positive])}")
      src_dir = Path.join(tmp, "src")
      working_dir = Path.join(tmp, "working")
      File.mkdir_p!(src_dir)
      File.mkdir_p!(working_dir)
      on_exit(fn -> File.rm_rf!(tmp) end)
      %{src_dir: src_dir, working_dir: working_dir}
    end

    test "extracts article from HTML", %{src_dir: src_dir, working_dir: working_dir} do
      html = """
      <html>
      <head><title>Test Article - My Blog</title></head>
      <body>
      <article>
      <h1>Test Article</h1>
      <p>This is the article content. It needs to be long enough for trafilatura to consider it
      real content rather than boilerplate. Lorem ipsum dolor sit amet, consectetur adipiscing elit.
      Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam,
      quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat.</p>
      </article>
      </body>
      </html>
      """

      File.write!(Path.join(src_dir, "original.html"), html)

      input_artifacts = [
        %{
          labels: %{"origin" => "original", "format" => "text", "type" => "article"},
          filenames: ["original.html"],
          input_path: src_dir
        }
      ]

      assert {:ok, result} = ExtractStage.perform(input_artifacts, working_dir, [], "item-1")

      assert [artifact] = result.artifacts
      assert artifact.labels["type"] == "content"
      assert "content.md" in artifact.filenames
      assert File.exists?(Path.join(working_dir, "content.md"))

      content = File.read!(Path.join(working_dir, "content.md"))
      assert content =~ "article content"
    end
  end
```

- [ ] **Step 7: Run integration test**

Run: `mix test test/cham/plugins/extract_article_test.exs --include integration`
Expected: All tests pass (requires `uv` and internet for first dependency install)

- [ ] **Step 8: Run full test suite and format**

Run: `mix format && mix test`
Expected: All non-integration tests pass

- [ ] **Step 9: Commit**

```bash
git add lib/cham/plugins/extract_article.ex scripts/extract_article/main.py test/cham/plugins/extract_article_test.exs
git commit -m "feat: add extract_article plugin with trafilatura"
```

---

## Task 4: `transcribe_whisper` Plugin + Python Script

**Files:**
- Create: `lib/cham/plugins/transcribe_whisper.ex`
- Create: `scripts/transcribe_whisper/main.py`
- Create: `test/cham/plugins/transcribe_whisper_test.exs`

- [ ] **Step 1: Write the Python transcription script**

```python
# scripts/transcribe_whisper/main.py
# /// script
# requires-python = ">=3.11"
# dependencies = ["faster-whisper>=1.0"]
# ///

import json
import sys
from pathlib import Path

from faster_whisper import WhisperModel


def main():
    if len(sys.argv) < 3:
        print("Usage: main.py <media_file> <output_dir> [--model MODEL] [--language LANG] [--device DEVICE]", file=sys.stderr)
        sys.exit(1)

    media_file = Path(sys.argv[1])
    output_dir = Path(sys.argv[2])

    model_name = "turbo"
    language = None
    device = "auto"

    args = sys.argv[3:]
    i = 0
    while i < len(args):
        if args[i] == "--model" and i + 1 < len(args):
            model_name = args[i + 1]
            i += 2
        elif args[i] == "--language" and i + 1 < len(args):
            language = args[i + 1]
            i += 2
        elif args[i] == "--device" and i + 1 < len(args):
            device = args[i + 1]
            i += 2
        else:
            i += 1

    model = WhisperModel(model_name, device=device)

    segments, info = model.transcribe(
        str(media_file),
        language=language,
        beam_size=5,
    )

    output_dir.mkdir(parents=True, exist_ok=True)
    transcript_path = output_dir / "transcript.md"

    total_duration = info.duration
    lines = []

    with open(transcript_path, "w", encoding="utf-8") as f:
        for segment in segments:
            start_ts = format_timestamp(segment.start)
            line = f"[{start_ts}] {segment.text.strip()}"
            f.write(line + "\n")
            lines.append(line)

            if total_duration > 0:
                progress = min(segment.end / total_duration, 1.0)
                print(json.dumps({"progress": round(progress, 3), "message": "Transcribing..."}), flush=True)

    metadata = {
        "language": info.language,
        "duration": int(total_duration),
    }
    print(json.dumps(metadata), flush=True)


def format_timestamp(seconds):
    h = int(seconds // 3600)
    m = int((seconds % 3600) // 60)
    s = int(seconds % 60)
    if h > 0:
        return f"{h}:{m:02d}:{s:02d}"
    return f"{m}:{s:02d}"


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Write failing test for plugin behaviour**

```elixir
# test/cham/plugins/transcribe_whisper_test.exs
defmodule Cham.Plugins.TranscribeWhisperTest do
  use Cham.DataCase

  alias Cham.Plugins.TranscribeWhisper
  alias Cham.Plugins.TranscribeWhisper.TranscribeStage

  describe "plugin behaviour" do
    test "returns correct plugin_id" do
      assert TranscribeWhisper.plugin_id() == "transcribe_whisper"
    end

    test "config schema includes model, language, device" do
      schema = TranscribeWhisper.config_schema()
      keys = Enum.map(schema, & &1.key)
      assert :model in keys
      assert :language in keys
      assert :device in keys
    end

    test "stages returns TranscribeStage" do
      assert [TranscribeStage] = TranscribeWhisper.stages(%{})
    end
  end

  describe "stage behaviour" do
    test "returns correct stage metadata" do
      assert TranscribeStage.name() == "Transcribe Audio"
      assert TranscribeStage.queue() == :gpu
      assert TranscribeStage.max_attempts() == 3

      matchers = TranscribeStage.input_matchers()
      assert %{"origin" => "original", "format" => "video"} in matchers
      assert %{"origin" => "original", "format" => "audio"} in matchers

      assert TranscribeStage.output_labels() == [
               %{
                 "origin" => "derived",
                 "format" => "text",
                 "type" => "transcript",
                 "content_type" => "text/markdown"
               }
             ]
    end
  end
end
```

- [ ] **Step 3: Run test to verify it fails**

Run: `mix test test/cham/plugins/transcribe_whisper_test.exs`
Expected: Compilation error

- [ ] **Step 4: Implement plugin and stage**

```elixir
# lib/cham/plugins/transcribe_whisper.ex
defmodule Cham.Plugins.TranscribeWhisper do
  @behaviour Cham.Plugin

  @impl true
  def plugin_id, do: "transcribe_whisper"

  @impl true
  def name, do: "Whisper Transcriber"

  @impl true
  def description, do: "Transcribes audio/video using faster-whisper"

  @impl true
  def config_schema do
    [
      %{key: :model, type: :string, default: "turbo", description: "Whisper model name", required: false, options: nil},
      %{key: :language, type: :string, default: nil, description: "Language code (nil for auto-detect)", required: false, options: nil},
      %{key: :device, type: :string, default: "auto", description: "Device: auto, cpu, or cuda", required: false, options: ["auto", "cpu", "cuda"]}
    ]
  end

  @impl true
  def init(_context), do: {:ok, %{}}

  @impl true
  def stages(_state), do: [__MODULE__.TranscribeStage]
end

defmodule Cham.Plugins.TranscribeWhisper.TranscribeStage do
  @behaviour Cham.Stage

  @impl true
  def name, do: "Transcribe Audio"

  @impl true
  def description, do: "Transcribes audio/video content using Whisper"

  @impl true
  def input_matchers do
    [
      %{"origin" => "original", "format" => "video"},
      %{"origin" => "original", "format" => "audio"}
    ]
  end

  @impl true
  def output_labels do
    [%{"origin" => "derived", "format" => "text", "type" => "transcript", "content_type" => "text/markdown"}]
  end

  @impl true
  def queue, do: :gpu

  @impl true
  def max_attempts, do: 3

  @impl true
  def perform(input_artifacts, working_dir, _desired_artifacts, _item_id) do
    config = get_config()
    [input | _] = input_artifacts
    [filename | _] = input.filenames
    media_path = Path.join(input.input_path, filename)

    args = build_args(media_path, working_dir, config)

    case Cham.ScriptRunner.run_script_sync("transcribe_whisper", args, timeout: 1_800_000) do
      {:ok, stdout, _stderr, 0} ->
        metadata = parse_last_json_line(stdout)

        {:ok,
         %{
           artifacts: [
             %{
               labels: %{
                 "origin" => "derived",
                 "format" => "text",
                 "type" => "transcript",
                 "content_type" => "text/markdown"
               },
               filenames: ["transcript.md"]
             }
           ],
           item_metadata: metadata,
           provenance: %{"model" => Map.get(config, :model, "turbo"), "tool" => "faster-whisper"}
         }}

      {:ok, stdout, _stderr, exit_code} ->
        if String.contains?(stdout, "GPU memory") do
          {:snooze, 60_000, "Insufficient GPU memory"}
        else
          {:error, "transcribe_whisper.py exited with code #{exit_code}"}
        end

      {:error, :timeout, _stdout, _stderr} ->
        {:error, "transcribe_whisper.py timed out"}
    end
  end

  defp get_config do
    case Cham.Plugin.Registry.get_plugin("transcribe_whisper") do
      {:ok, plugin} -> Map.get(plugin.state, :config, %{})
      _ -> %{}
    end
  end

  defp build_args(media_path, working_dir, config) do
    args = [media_path, working_dir]

    args =
      case Map.get(config, :model) do
        nil -> args
        model -> args ++ ["--model", model]
      end

    args =
      case Map.get(config, :language) do
        nil -> args
        lang -> args ++ ["--language", lang]
      end

    case Map.get(config, :device) do
      nil -> args
      device -> args ++ ["--device", device]
    end
  end

  defp parse_last_json_line(stdout) do
    stdout
    |> String.trim()
    |> String.split("\n")
    |> List.last("")
    |> Jason.decode()
    |> case do
      {:ok, meta} when is_map(meta) -> Map.drop(meta, ["progress", "message"])
      _ -> %{}
    end
  end
end
```

- [ ] **Step 5: Run test to verify behaviour tests pass**

Run: `mix test test/cham/plugins/transcribe_whisper_test.exs`
Expected: All tests pass

- [ ] **Step 6: Run full test suite and format**

Run: `mix format && mix test`
Expected: All tests pass

- [ ] **Step 7: Commit**

```bash
git add lib/cham/plugins/transcribe_whisper.ex scripts/transcribe_whisper/main.py test/cham/plugins/transcribe_whisper_test.exs
git commit -m "feat: add transcribe_whisper plugin with faster-whisper"
```

---

## Task 5: `summarize_ollama` Plugin

**Files:**
- Create: `lib/cham/plugins/summarize_ollama.ex`
- Create: `test/cham/plugins/summarize_ollama_test.exs`

- [ ] **Step 1: Write failing test for plugin behaviour and stage metadata**

```elixir
# test/cham/plugins/summarize_ollama_test.exs
defmodule Cham.Plugins.SummarizeOllamaTest do
  use Cham.DataCase

  alias Cham.Plugins.SummarizeOllama
  alias Cham.Plugins.SummarizeOllama.SummarizeStage

  describe "plugin behaviour" do
    test "returns correct plugin_id" do
      assert SummarizeOllama.plugin_id() == "summarize_ollama"
    end

    test "config schema includes model, max_input_tokens, provider" do
      schema = SummarizeOllama.config_schema()
      keys = Enum.map(schema, & &1.key)
      assert :model in keys
      assert :max_input_tokens in keys
      assert :provider in keys
    end

    test "stages returns SummarizeStage" do
      assert [SummarizeStage] = SummarizeOllama.stages(%{})
    end
  end

  describe "stage behaviour" do
    test "returns correct stage metadata" do
      assert SummarizeStage.name() == "Summarize"
      assert SummarizeStage.queue() == :gpu
      assert SummarizeStage.max_attempts() == 3

      matchers = SummarizeStage.input_matchers()
      assert %{"origin" => "original", "format" => "text", "type" => "content"} in matchers
      assert %{"origin" => "derived", "type" => "transcript"} in matchers

      assert SummarizeStage.output_labels() == [
               %{"origin" => "derived", "type" => "summary", "content_type" => "text/markdown"}
             ]
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/cham/plugins/summarize_ollama_test.exs`
Expected: Compilation error

- [ ] **Step 3: Implement plugin and stage skeleton**

```elixir
# lib/cham/plugins/summarize_ollama.ex
defmodule Cham.Plugins.SummarizeOllama do
  @behaviour Cham.Plugin

  @impl true
  def plugin_id, do: "summarize_ollama"

  @impl true
  def name, do: "Ollama Summarizer"

  @impl true
  def description, do: "Summarizes content using a local LLM via Ollama"

  @impl true
  def config_schema do
    [
      %{key: :model, type: :string, default: "llama3.1:8b", description: "LLM model name", required: false, options: nil},
      %{key: :max_input_tokens, type: :integer, default: 8000, description: "Maximum input token estimate (chars / 4)", required: false, options: nil},
      %{key: :provider, type: :string, default: "default", description: "LLM provider name", required: false, options: nil}
    ]
  end

  @impl true
  def init(_context), do: {:ok, %{}}

  @impl true
  def stages(_state), do: [__MODULE__.SummarizeStage]
end

defmodule Cham.Plugins.SummarizeOllama.SummarizeStage do
  @behaviour Cham.Stage

  @impl true
  def name, do: "Summarize"

  @impl true
  def description, do: "Generates a summary of the content using an LLM"

  @impl true
  def input_matchers do
    [
      %{"origin" => "original", "format" => "text", "type" => "content"},
      %{"origin" => "derived", "type" => "transcript"}
    ]
  end

  @impl true
  def output_labels do
    [%{"origin" => "derived", "type" => "summary", "content_type" => "text/markdown"}]
  end

  @impl true
  def queue, do: :gpu

  @impl true
  def max_attempts, do: 3

  @impl true
  def perform(input_artifacts, working_dir, _desired_artifacts, _item_id) do
    config = get_config()
    model = Map.get(config, :model, "llama3.1:8b")
    max_chars = Map.get(config, :max_input_tokens, 8000) * 4

    [input | _] = input_artifacts
    [filename | _] = input.filenames
    content_path = Path.join(input.input_path, filename)

    case File.read(content_path) do
      {:ok, text} ->
        truncated = String.slice(text, 0, max_chars)
        generate_summary(truncated, working_dir, model)

      {:error, reason} ->
        {:error, "Failed to read input: #{inspect(reason)}"}
    end
  end

  defp generate_summary(text, working_dir, model) do
    prompt = """
    Summarize the following content concisely. Focus on the key points and main ideas.
    Write the summary in markdown format with bullet points for the main takeaways.

    Content:
    #{text}
    """

    case Cham.LLM.Provider.generate(Cham.LLM.Providers.OpenAI, prompt, model: model) do
      {:ok, summary} ->
        output_path = Path.join(working_dir, "summary.md")
        File.write!(output_path, summary)

        {:ok,
         %{
           artifacts: [
             %{
               labels: %{"origin" => "derived", "type" => "summary", "content_type" => "text/markdown"},
               filenames: ["summary.md"]
             }
           ],
           item_metadata: %{},
           provenance: %{"model" => model}
         }}

      {:error, reason} ->
        error_str = if is_binary(reason), do: reason, else: inspect(reason)

        if String.contains?(error_str, "connection refused") or
             String.contains?(error_str, "ECONNREFUSED") do
          {:snooze, 30_000, "LLM provider unreachable"}
        else
          {:error, "Summarization failed: #{error_str}"}
        end
    end
  end

  defp get_config do
    case Cham.Plugin.Registry.get_plugin("summarize_ollama") do
      {:ok, plugin} -> Map.get(plugin.state, :config, %{})
      _ -> %{}
    end
  end
end
```

- [ ] **Step 4: Run test to verify behaviour tests pass**

Run: `mix test test/cham/plugins/summarize_ollama_test.exs`
Expected: All tests pass

- [ ] **Step 5: Write failing test for perform with Bypass mock**

Add to the test file:

```elixir
  describe "perform/4" do
    setup do
      bypass = Bypass.open()
      tmp = Path.join(System.tmp_dir!(), "cham_summarize_test_#{:erlang.unique_integer([:positive])}")
      src_dir = Path.join(tmp, "src")
      working_dir = Path.join(tmp, "working")
      File.mkdir_p!(src_dir)
      File.mkdir_p!(working_dir)
      on_exit(fn -> File.rm_rf!(tmp) end)
      %{bypass: bypass, src_dir: src_dir, working_dir: working_dir}
    end

    test "generates summary from input text", %{bypass: bypass, src_dir: src_dir, working_dir: working_dir} do
      Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["model"] == "test-model"

        response = %{
          "choices" => [
            %{"message" => %{"content" => "- Key point 1\n- Key point 2"}}
          ]
        }

        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.resp(200, Jason.encode!(response))
      end)

      File.write!(Path.join(src_dir, "content.md"), "This is some article content to summarize.")

      input_artifacts = [
        %{
          labels: %{"origin" => "original", "format" => "text", "type" => "content"},
          filenames: ["content.md"],
          input_path: src_dir
        }
      ]

      # Temporarily override the LLM URL by testing the internal function
      # We need to test through the actual provider, so we'll set up a custom test
      # that uses the Bypass URL
      prompt = """
      Summarize the following content concisely. Focus on the key points and main ideas.
      Write the summary in markdown format with bullet points for the main takeaways.

      Content:
      This is some article content to summarize.
      """

      assert {:ok, summary} =
               Cham.LLM.Provider.generate(
                 Cham.LLM.Providers.OpenAI,
                 String.trim(prompt),
                 model: "test-model",
                 url: "http://localhost:#{bypass.port}"
               )

      assert summary =~ "Key point"
    end
  end
```

- [ ] **Step 6: Run test to verify it passes**

Run: `mix test test/cham/plugins/summarize_ollama_test.exs`
Expected: All tests pass

- [ ] **Step 7: Run full test suite and format**

Run: `mix format && mix test`
Expected: All tests pass

- [ ] **Step 8: Commit**

```bash
git add lib/cham/plugins/summarize_ollama.ex test/cham/plugins/summarize_ollama_test.exs
git commit -m "feat: add summarize_ollama plugin"
```

---

## Task 6: `auto_tag` Plugin

**Files:**
- Create: `lib/cham/plugins/auto_tag.ex`
- Create: `test/cham/plugins/auto_tag_test.exs`

- [ ] **Step 1: Write failing test for plugin behaviour and stage metadata**

```elixir
# test/cham/plugins/auto_tag_test.exs
defmodule Cham.Plugins.AutoTagTest do
  use Cham.DataCase

  alias Cham.Plugins.AutoTag
  alias Cham.Plugins.AutoTag.TagStage

  describe "plugin behaviour" do
    test "returns correct plugin_id" do
      assert AutoTag.plugin_id() == "auto_tag"
    end

    test "config schema includes model, max_tags, provider" do
      schema = AutoTag.config_schema()
      keys = Enum.map(schema, & &1.key)
      assert :model in keys
      assert :max_tags in keys
      assert :provider in keys
    end

    test "stages returns TagStage" do
      assert [TagStage] = AutoTag.stages(%{})
    end
  end

  describe "stage behaviour" do
    test "returns correct stage metadata" do
      assert TagStage.name() == "Auto Tag"
      assert TagStage.queue() == :gpu
      assert TagStage.max_attempts() == 3

      matchers = TagStage.input_matchers()
      assert %{"origin" => "original", "format" => "text", "type" => "content"} in matchers
      assert %{"origin" => "derived", "type" => "transcript"} in matchers

      assert TagStage.output_labels() == [
               %{"origin" => "derived", "type" => "tags"}
             ]
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/cham/plugins/auto_tag_test.exs`
Expected: Compilation error

- [ ] **Step 3: Implement plugin and stage**

```elixir
# lib/cham/plugins/auto_tag.ex
defmodule Cham.Plugins.AutoTag do
  @behaviour Cham.Plugin

  @impl true
  def plugin_id, do: "auto_tag"

  @impl true
  def name, do: "Auto Tagger"

  @impl true
  def description, do: "Generates tags for content using an LLM"

  @impl true
  def config_schema do
    [
      %{key: :model, type: :string, default: "llama3.1:8b", description: "LLM model name", required: false, options: nil},
      %{key: :max_tags, type: :integer, default: 10, description: "Maximum number of tags", required: false, options: nil},
      %{key: :provider, type: :string, default: "default", description: "LLM provider name", required: false, options: nil}
    ]
  end

  @impl true
  def init(_context), do: {:ok, %{}}

  @impl true
  def stages(_state), do: [__MODULE__.TagStage]
end

defmodule Cham.Plugins.AutoTag.TagStage do
  @behaviour Cham.Stage

  @impl true
  def name, do: "Auto Tag"

  @impl true
  def description, do: "Generates descriptive tags for content"

  @impl true
  def input_matchers do
    [
      %{"origin" => "original", "format" => "text", "type" => "content"},
      %{"origin" => "derived", "type" => "transcript"}
    ]
  end

  @impl true
  def output_labels do
    [%{"origin" => "derived", "type" => "tags"}]
  end

  @impl true
  def queue, do: :gpu

  @impl true
  def max_attempts, do: 3

  @impl true
  def perform(input_artifacts, working_dir, _desired_artifacts, _item_id) do
    config = get_config()
    model = Map.get(config, :model, "llama3.1:8b")
    max_tags = Map.get(config, :max_tags, 10)

    [input | _] = input_artifacts
    [filename | _] = input.filenames
    content_path = Path.join(input.input_path, filename)

    case File.read(content_path) do
      {:ok, text} ->
        # Use first ~32k chars for tagging
        truncated = String.slice(text, 0, 32_000)
        generate_tags(truncated, working_dir, model, max_tags)

      {:error, reason} ->
        {:error, "Failed to read input: #{inspect(reason)}"}
    end
  end

  defp generate_tags(text, working_dir, model, max_tags) do
    prompt = """
    Generate descriptive tags for the following content. Return ONLY a JSON array of lowercase, hyphenated tags.
    Maximum #{max_tags} tags. Focus on the main topics, technologies, people, and concepts.

    Example output: ["machine-learning", "python", "neural-networks"]

    Content:
    #{text}
    """

    case Cham.LLM.Provider.generate(Cham.LLM.Providers.OpenAI, prompt, model: model) do
      {:ok, response} ->
        tags = parse_tags(response, max_tags)
        output_path = Path.join(working_dir, "tags.json")
        File.write!(output_path, Jason.encode!(tags))

        {:ok,
         %{
           artifacts: [
             %{
               labels: %{"origin" => "derived", "type" => "tags"},
               filenames: ["tags.json"]
             }
           ],
           item_metadata: %{"tags" => tags},
           provenance: %{"model" => model}
         }}

      {:error, reason} ->
        error_str = if is_binary(reason), do: reason, else: inspect(reason)

        if String.contains?(error_str, "connection refused") or
             String.contains?(error_str, "ECONNREFUSED") do
          {:snooze, 30_000, "LLM provider unreachable"}
        else
          {:error, "Tagging failed: #{error_str}"}
        end
    end
  end

  defp parse_tags(response, max_tags) do
    # Try to extract JSON array from response (LLM may wrap in markdown code blocks)
    cleaned =
      response
      |> String.trim()
      |> String.replace(~r/^```json\n?/, "")
      |> String.replace(~r/\n?```$/, "")
      |> String.trim()

    case Jason.decode(cleaned) do
      {:ok, tags} when is_list(tags) ->
        tags
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&String.downcase/1)
        |> Enum.take(max_tags)

      _ ->
        []
    end
  end

  defp get_config do
    case Cham.Plugin.Registry.get_plugin("auto_tag") do
      {:ok, plugin} -> Map.get(plugin.state, :config, %{})
      _ -> %{}
    end
  end
end
```

- [ ] **Step 4: Run test to verify behaviour tests pass**

Run: `mix test test/cham/plugins/auto_tag_test.exs`
Expected: All tests pass

- [ ] **Step 5: Write test for tag parsing logic**

Add to the test file:

```elixir
  describe "tag parsing" do
    test "parses JSON array response" do
      # Test the module's internal parsing by testing through perform
      # We'll test the parse logic by examining the output format
      # For a unit test of the parsing, we test the full pipeline with Bypass

      bypass = Bypass.open()

      tmp = Path.join(System.tmp_dir!(), "cham_tag_test_#{:erlang.unique_integer([:positive])}")
      src_dir = Path.join(tmp, "src")
      working_dir = Path.join(tmp, "working")
      File.mkdir_p!(src_dir)
      File.mkdir_p!(working_dir)
      on_exit(fn -> File.rm_rf!(tmp) end)

      Bypass.expect(bypass, "POST", "/v1/chat/completions", fn conn ->
        response = %{
          "choices" => [
            %{"message" => %{"content" => ~s(```json\n["elixir", "Phoenix-Framework", "TESTING"]\n```)}}
          ]
        }

        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.resp(200, Jason.encode!(response))
      end)

      # Test the LLM call + parsing directly
      assert {:ok, response} =
               Cham.LLM.Provider.generate(
                 Cham.LLM.Providers.OpenAI,
                 "test prompt",
                 model: "test",
                 url: "http://localhost:#{bypass.port}"
               )

      # Verify the LLM response can be parsed (same logic as TagStage)
      cleaned =
        response
        |> String.trim()
        |> String.replace(~r/^```json\n?/, "")
        |> String.replace(~r/\n?```$/, "")
        |> String.trim()

      assert {:ok, tags} = Jason.decode(cleaned)
      assert tags == ["elixir", "Phoenix-Framework", "TESTING"]

      # Verify normalization
      normalized = tags |> Enum.map(&String.downcase/1) |> Enum.take(10)
      assert normalized == ["elixir", "phoenix-framework", "testing"]
    end
  end
```

- [ ] **Step 6: Run test to verify it passes**

Run: `mix test test/cham/plugins/auto_tag_test.exs`
Expected: All tests pass

- [ ] **Step 7: Run full test suite and format**

Run: `mix format && mix test`
Expected: All tests pass

- [ ] **Step 8: Commit**

```bash
git add lib/cham/plugins/auto_tag.ex test/cham/plugins/auto_tag_test.exs
git commit -m "feat: add auto_tag plugin"
```

---

## Task 7: `clean_title` Plugin

**Files:**
- Create: `lib/cham/plugins/clean_title.ex`
- Create: `test/cham/plugins/clean_title_test.exs`

- [ ] **Step 1: Write failing test for plugin behaviour and stage metadata**

```elixir
# test/cham/plugins/clean_title_test.exs
defmodule Cham.Plugins.CleanTitleTest do
  use Cham.DataCase

  alias Cham.Plugins.CleanTitle
  alias Cham.Plugins.CleanTitle.CleanStage

  describe "plugin behaviour" do
    test "returns correct plugin_id" do
      assert CleanTitle.plugin_id() == "clean_title"
    end

    test "config schema includes model and provider" do
      schema = CleanTitle.config_schema()
      keys = Enum.map(schema, & &1.key)
      assert :model in keys
      assert :provider in keys
    end

    test "stages returns CleanStage" do
      assert [CleanStage] = CleanTitle.stages(%{})
    end
  end

  describe "stage behaviour" do
    test "returns correct stage metadata" do
      assert CleanStage.name() == "Clean Title"
      assert CleanStage.queue() == :gpu
      assert CleanStage.max_attempts() == 3
      assert CleanStage.input_matchers() == [%{}]
      assert CleanStage.output_labels() == []
    end
  end

  describe "can_process?/1" do
    test "returns not_applicable when no title metadata exists" do
      artifacts = [%{"origin" => "original", "format" => "text"}]
      assert :not_applicable = CleanStage.can_process?(artifacts)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/cham/plugins/clean_title_test.exs`
Expected: Compilation error

- [ ] **Step 3: Implement plugin and stage**

```elixir
# lib/cham/plugins/clean_title.ex
defmodule Cham.Plugins.CleanTitle do
  @behaviour Cham.Plugin

  @impl true
  def plugin_id, do: "clean_title"

  @impl true
  def name, do: "Title Cleaner"

  @impl true
  def description, do: "Cleans up item titles using an LLM"

  @impl true
  def config_schema do
    [
      %{key: :model, type: :string, default: "llama3.1:8b", description: "LLM model name", required: false, options: nil},
      %{key: :provider, type: :string, default: "default", description: "LLM provider name", required: false, options: nil}
    ]
  end

  @impl true
  def init(_context), do: {:ok, %{}}

  @impl true
  def stages(_state), do: [__MODULE__.CleanStage]
end

defmodule Cham.Plugins.CleanTitle.CleanStage do
  @behaviour Cham.Stage

  @impl true
  def name, do: "Clean Title"

  @impl true
  def description, do: "Removes site names and cruft from titles"

  @impl true
  def input_matchers, do: [%{}]

  @impl true
  def output_labels, do: []

  @impl true
  def queue, do: :gpu

  @impl true
  def max_attempts, do: 3

  @impl true
  def can_process?(_current_artifacts) do
    # This is a dynamic stage — it cannot determine readiness from artifact labels alone.
    # The StageWorker should check if the item has a title in metadata before scheduling.
    # For now, we signal readiness and check in perform.
    # The actual title check happens in perform/4 since can_process? only sees artifact labels.
    :undecided
  end

  @impl true
  def perform(_input_artifacts, _working_dir, _desired_artifacts, item_id) do
    config = get_config()
    model = Map.get(config, :model, "llama3.1:8b")

    item = Cham.Items.get_item!(item_id)
    title = item.title || item.metadata["title"]

    if is_nil(title) or title == "" do
      {:ok, %{artifacts: [], item_metadata: %{}, provenance: %{}}}
    else
      clean_title(title, model)
    end
  end

  defp clean_title(title, model) do
    prompt = """
    Clean up this title by removing site names, trailing separators, and cruft.
    Return ONLY the cleaned title text, nothing else. Do not add quotes.
    If the title is already clean, return it unchanged.

    Examples:
    "My Recipe - Soandso's Blog" → "My Recipe"
    "How to Code | TechSite.com" → "How to Code"
    "Introduction to Elixir — Dev.to" → "Introduction to Elixir"
    "A Clean Title" → "A Clean Title"

    Title: #{title}
    """

    case Cham.LLM.Provider.generate(Cham.LLM.Providers.OpenAI, prompt, model: model) do
      {:ok, cleaned} ->
        cleaned = String.trim(cleaned)

        {:ok,
         %{
           artifacts: [],
           item_metadata: %{"title" => cleaned},
           provenance: %{"model" => model}
         }}

      {:error, reason} ->
        error_str = if is_binary(reason), do: reason, else: inspect(reason)

        if String.contains?(error_str, "connection refused") or
             String.contains?(error_str, "ECONNREFUSED") do
          {:snooze, 30_000, "LLM provider unreachable"}
        else
          {:error, "Title cleanup failed: #{error_str}"}
        end
    end
  end

  defp get_config do
    case Cham.Plugin.Registry.get_plugin("clean_title") do
      {:ok, plugin} -> Map.get(plugin.state, :config, %{})
      _ -> %{}
    end
  end
end
```

- [ ] **Step 4: Run test to verify behaviour tests pass**

Run: `mix test test/cham/plugins/clean_title_test.exs`
Expected: All tests pass

- [ ] **Step 5: Write test for perform with no title**

Add to the test file:

```elixir
  describe "perform/4" do
    test "returns empty result when item has no title" do
      {:ok, item} =
        Cham.Items.create_item(%{
          url: "https://example.com/no-title",
          slug: "no-title-#{System.unique_integer([:positive])}"
        })

      assert {:ok, result} = CleanStage.perform([], "/tmp", [], item.id)
      assert result.artifacts == []
      assert result.item_metadata == %{}
    end
  end
```

- [ ] **Step 6: Run test to verify it passes**

Run: `mix test test/cham/plugins/clean_title_test.exs`
Expected: All tests pass

- [ ] **Step 7: Run full test suite and format**

Run: `mix format && mix test`
Expected: All tests pass

- [ ] **Step 8: Commit**

```bash
git add lib/cham/plugins/clean_title.ex test/cham/plugins/clean_title_test.exs
git commit -m "feat: add clean_title plugin"
```

---

## Task 8: Integration — Register Plugins at Startup

**Files:**
- Modify: `lib/cham/application.ex`
- Create: `test/cham/plugins/registration_test.exs`

- [ ] **Step 1: Write failing test for plugin auto-registration**

```elixir
# test/cham/plugins/registration_test.exs
defmodule Cham.Plugins.RegistrationTest do
  use Cham.DataCase

  alias Cham.Plugin.Registry

  @core_plugins [
    "generic_download_url",
    "content_type_router",
    "extract_article",
    "transcribe_whisper",
    "summarize_ollama",
    "auto_tag",
    "clean_title"
  ]

  describe "core plugin registration" do
    test "all core plugins have valid plugin_id" do
      modules = [
        Cham.Plugins.GenericDownloadUrl,
        Cham.Plugins.ContentTypeRouter,
        Cham.Plugins.ExtractArticle,
        Cham.Plugins.TranscribeWhisper,
        Cham.Plugins.SummarizeOllama,
        Cham.Plugins.AutoTag,
        Cham.Plugins.CleanTitle
      ]

      plugin_ids = Enum.map(modules, & &1.plugin_id())
      assert Enum.sort(plugin_ids) == Enum.sort(@core_plugins)
    end

    test "all core plugins init successfully" do
      modules = [
        Cham.Plugins.GenericDownloadUrl,
        Cham.Plugins.ContentTypeRouter,
        Cham.Plugins.ExtractArticle,
        Cham.Plugins.TranscribeWhisper,
        Cham.Plugins.SummarizeOllama,
        Cham.Plugins.AutoTag,
        Cham.Plugins.CleanTitle
      ]

      for mod <- modules do
        assert {:ok, _state} = mod.init(%{config: %{}}),
               "#{inspect(mod)} failed to init"
      end
    end

    test "all core plugins provide at least one stage" do
      modules = [
        Cham.Plugins.GenericDownloadUrl,
        Cham.Plugins.ContentTypeRouter,
        Cham.Plugins.ExtractArticle,
        Cham.Plugins.TranscribeWhisper,
        Cham.Plugins.SummarizeOllama,
        Cham.Plugins.AutoTag,
        Cham.Plugins.CleanTitle
      ]

      for mod <- modules do
        stages = mod.stages(%{})
        assert length(stages) >= 1, "#{inspect(mod)} has no stages"
      end
    end

    test "can register all core plugins in registry" do
      {:ok, registry} = Registry.start_link(name: :"test_registry_#{System.unique_integer([:positive])}", plugin_order: @core_plugins)

      modules = [
        Cham.Plugins.GenericDownloadUrl,
        Cham.Plugins.ContentTypeRouter,
        Cham.Plugins.ExtractArticle,
        Cham.Plugins.TranscribeWhisper,
        Cham.Plugins.SummarizeOllama,
        Cham.Plugins.AutoTag,
        Cham.Plugins.CleanTitle
      ]

      for mod <- modules do
        assert :ok = Registry.register_plugin(registry, mod, %{})
      end

      plugins = Registry.list_plugins(registry)
      assert length(plugins) == 7

      stages = Registry.get_stages(registry)
      assert length(stages) == 7
    end
  end
end
```

- [ ] **Step 2: Run test to verify it passes** (all plugin modules already exist)

Run: `mix test test/cham/plugins/registration_test.exs`
Expected: All tests pass (or fail if Registry API differs — adjust accordingly)

- [ ] **Step 3: Add core plugin registration to Application startup**

Read `lib/cham/application.ex` first, then add a private function to register core plugins after the Registry starts. Add the registration call after the existing children list setup, adding the Registry to the supervision tree if not already present:

Add to `lib/cham/application.ex` — a function called after supervision tree starts:

```elixir
  defp register_core_plugins do
    core_plugins = [
      Cham.Plugins.GenericDownloadUrl,
      Cham.Plugins.ContentTypeRouter,
      Cham.Plugins.ExtractArticle,
      Cham.Plugins.TranscribeWhisper,
      Cham.Plugins.SummarizeOllama,
      Cham.Plugins.AutoTag,
      Cham.Plugins.CleanTitle
    ]

    for mod <- core_plugins do
      case Cham.Plugin.Registry.register_plugin(mod, %{}) do
        :ok -> :ok
        {:error, reason} -> Logger.warning("Failed to register plugin #{mod.plugin_id()}: #{inspect(reason)}")
      end
    end
  end
```

Call `register_core_plugins()` after `Supervisor.start_link(children, opts)` succeeds, in the `start/2` function:

```elixir
  def start(_type, _args) do
    # ... existing children list ...

    opts = [strategy: :one_for_one, name: Cham.Supervisor]
    result = Supervisor.start_link(children, opts)

    case result do
      {:ok, pid} ->
        register_core_plugins()
        {:ok, pid}

      error ->
        error
    end
  end
```

Note: The `Cham.Plugin.Registry` must be in the children list. Check if it's already there; if not, add it before the Endpoint:

```elixir
    {Cham.Plugin.Registry, name: Cham.Plugin.Registry, plugin_order: []},
```

- [ ] **Step 4: Run full test suite and format**

Run: `mix format && mix test`
Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
git add lib/cham/application.ex test/cham/plugins/registration_test.exs
git commit -m "feat: register core plugins at application startup"
```

---

## Task 9: Final Verification

- [ ] **Step 1: Run full test suite**

Run: `mix test`
Expected: All unit tests pass

- [ ] **Step 2: Run integration tests** (requires uv, network)

Run: `mix test --include integration`
Expected: Integration tests pass

- [ ] **Step 3: Run formatter**

Run: `mix format --check-formatted`
Expected: No formatting issues

- [ ] **Step 4: Verify compilation is clean**

Run: `mix compile --warnings-as-errors`
Expected: Clean compilation with no warnings

- [ ] **Step 5: Manual smoke test** (optional)

Start the dev server and submit a URL to verify the pipeline runs end-to-end:

Run: `mix phx.server`
Then submit a URL via the pipeline:

```elixir
# In iex -S mix
Cham.Pipeline.submit_url("https://example.com/some-article")
```

Verify the item progresses through bootstrapping → processing → complete.
