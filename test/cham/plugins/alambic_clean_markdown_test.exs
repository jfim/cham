defmodule Cham.Plugins.AlambicCleanMarkdownTest do
  use ExUnit.Case, async: false

  alias Cham.Plugins.AlambicCleanMarkdown
  alias Cham.Plugins.AlambicCleanMarkdown.CleanStage

  describe "plugin behaviour" do
    test "plugin_id" do
      assert AlambicCleanMarkdown.plugin_id() == "alambic_clean_markdown"
    end

    test "default_enabled? is false" do
      assert AlambicCleanMarkdown.default_enabled?() == false
    end

    test "config_schema has url (required, no default) and receive_timeout_ms (5 min default)" do
      schema = AlambicCleanMarkdown.config_schema()

      url = Enum.find(schema, &(&1.key == :url))
      assert url.required == true
      assert url.default == nil

      timeout = Enum.find(schema, &(&1.key == :receive_timeout_ms))
      assert timeout.default == 300_000
    end

    test "stages returns CleanStage" do
      assert [CleanStage] = AlambicCleanMarkdown.stages(%{})
    end
  end

  describe "stage metadata" do
    test "input_matchers targets ExtractArticle markdown output" do
      assert [
               %{
                 "origin" => "original",
                 "format" => "text",
                 "type" => "content",
                 "content_type" => "text/markdown"
               }
             ] = CleanStage.input_matchers()
    end

    test "output_labels emits cleaned_content (derived)" do
      [label] = CleanStage.output_labels()
      assert label["origin"] == "derived"
      assert label["type"] == "cleaned_content"
      assert label["content_type"] == "text/markdown"
    end

    test "queue is :network" do
      assert CleanStage.queue() == :network
    end
  end

  describe "can_process?" do
    test "ready when extracted article markdown present" do
      artifacts = [
        %{
          "origin" => "original",
          "format" => "text",
          "type" => "content",
          "content_type" => "text/markdown"
        }
      ]

      assert {:ready, _required, []} = CleanStage.can_process?(artifacts)
    end

    test "not applicable when only plaintext content present" do
      artifacts = [
        %{
          "origin" => "original",
          "format" => "text",
          "type" => "content",
          "content_type" => "text/plain"
        }
      ]

      assert :not_applicable = CleanStage.can_process?(artifacts)
    end

    test "not applicable for empty artifacts" do
      assert :not_applicable = CleanStage.can_process?([])
    end
  end

  describe "perform/4 with Bypass" do
    setup do
      bypass = Bypass.open()

      tag = System.unique_integer([:positive])
      input_dir = Path.join(System.tmp_dir!(), "cham_alambic_test_input_#{tag}")
      working_dir = Path.join(System.tmp_dir!(), "cham_alambic_test_work_#{tag}")
      File.mkdir_p!(input_dir)
      File.mkdir_p!(working_dir)

      on_exit(fn ->
        File.rm_rf!(input_dir)
        File.rm_rf!(working_dir)
      end)

      File.write!(Path.join(input_dir, "content.md"), "# Dirty\n\nSome junk and real text.")

      Cham.Config.Manager.register(
        "plugins.alambic_clean_markdown",
        AlambicCleanMarkdown.config_schema()
      )

      previous =
        case Cham.Config.Manager.read_raw("plugins.alambic_clean_markdown") do
          {:ok, raw} -> raw
          _ -> %{}
        end

      :ok =
        Cham.Config.Manager.write_all("plugins.alambic_clean_markdown", %{
          url: "http://localhost:#{bypass.port}",
          receive_timeout_ms: 5_000
        })

      on_exit(fn ->
        Cham.Config.Manager.write_all("plugins.alambic_clean_markdown", previous)
      end)

      input = %{
        labels: %{
          "origin" => "original",
          "format" => "text",
          "type" => "content",
          "content_type" => "text/markdown"
        },
        filenames: ["content.md"],
        input_path: input_dir
      }

      %{bypass: bypass, input: input, working_dir: working_dir}
    end

    test "writes cleaned_content.md and provenance on 200", %{
      bypass: bypass,
      input: input,
      working_dir: working_dir
    } do
      Bypass.expect_once(bypass, "POST", "/api/clean", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["item_id"] == "item-123"
        assert decoded["text"] == "# Dirty\n\nSome junk and real text."

        response = %{
          "item_id" => "item-123",
          "cleaned_text" => "# Clean\n\nReal text.",
          "source" => "model",
          "model_version" => "v1.2",
          "confidence" => 0.87
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(response))
      end)

      assert {:ok, result} = CleanStage.perform([input], working_dir, [], "item-123")

      [artifact] = result.artifacts
      assert artifact.labels["type"] == "cleaned_content"
      assert artifact.filenames == ["cleaned_content.md"]

      assert File.read!(Path.join(working_dir, "cleaned_content.md")) == "# Clean\n\nReal text."

      assert result.provenance["tool"] == "alambic"
      assert result.provenance["source"] == "model"
      assert result.provenance["model_version"] == "v1.2"
      assert result.provenance["confidence"] == 0.87
    end

    test "503 returns snooze", %{bypass: bypass, input: input, working_dir: working_dir} do
      Bypass.expect_once(bypass, "POST", "/api/clean", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(503, Jason.encode!(%{"error" => "no model available"}))
      end)

      assert {:snooze, delay, msg} = CleanStage.perform([input], working_dir, [], "item-123")
      assert is_integer(delay) and delay > 0
      assert msg =~ "service unavailable"
    end

    test "500 returns error", %{bypass: bypass, input: input, working_dir: working_dir} do
      Bypass.expect_once(bypass, "POST", "/api/clean", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(500, Jason.encode!(%{"error" => "inference failed"}))
      end)

      assert {:error, msg} = CleanStage.perform([input], working_dir, [], "item-123")
      assert msg =~ "500"
    end

    test "connection refused returns snooze", %{
      bypass: bypass,
      input: input,
      working_dir: working_dir
    } do
      Bypass.down(bypass)

      assert {:snooze, _delay, msg} = CleanStage.perform([input], working_dir, [], "item-123")
      assert msg =~ "connection refused"
    end
  end

  describe "perform/4 without configuration" do
    test "errors when url is unset" do
      Cham.Config.Manager.register(
        "plugins.alambic_clean_markdown",
        AlambicCleanMarkdown.config_schema()
      )

      previous =
        case Cham.Config.Manager.read_raw("plugins.alambic_clean_markdown") do
          {:ok, raw} -> raw
          _ -> %{}
        end

      :ok = Cham.Config.Manager.reset_key("plugins.alambic_clean_markdown", :url)
      on_exit(fn -> Cham.Config.Manager.write_all("plugins.alambic_clean_markdown", previous) end)

      input = %{
        labels: %{"origin" => "original", "format" => "text", "type" => "content"},
        filenames: ["content.md"],
        input_path: "/tmp"
      }

      assert {:error, msg} = CleanStage.perform([input], "/tmp", [], "item-1")
      assert msg =~ "url not configured"
    end
  end
end
