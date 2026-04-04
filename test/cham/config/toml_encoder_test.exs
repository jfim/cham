defmodule Cham.Config.TomlEncoderTest do
  use ExUnit.Case, async: true

  alias Cham.Config.TomlEncoder

  describe "encode/1" do
    test "encodes a single section with string, integer, and boolean values" do
      config = %{
        "worker" => %{
          "queue_general" => 5,
          "queue_network" => 3,
          "enabled" => true
        }
      }

      result = TomlEncoder.encode(config)

      assert result =~ "[worker]"
      assert result =~ "enabled = true"
      assert result =~ "queue_general = 5"
      assert result =~ "queue_network = 3"
    end

    test "encodes string values with quotes" do
      config = %{"archive" => %{"path" => "/data/archive"}}
      result = TomlEncoder.encode(config)
      assert result =~ ~s(path = "/data/archive")
    end

    test "encodes float values" do
      config = %{"tuning" => %{"rate" => 0.5}}
      result = TomlEncoder.encode(config)
      assert result =~ "rate = 0.5"
    end

    test "encodes list values" do
      config = %{"plugins" => %{"order" => ["whisper", "auto_tag", "summarize"]}}
      result = TomlEncoder.encode(config)
      assert result =~ ~s(order = ["whisper", "auto_tag", "summarize"])
    end

    test "encodes multiple sections sorted alphabetically" do
      config = %{
        "worker" => %{"concurrency" => 5},
        "archive" => %{"path" => "/data"}
      }

      result = TomlEncoder.encode(config)
      archive_pos = :binary.match(result, "[archive]") |> elem(0)
      worker_pos = :binary.match(result, "[worker]") |> elem(0)
      assert archive_pos < worker_pos
    end

    test "encodes dotted section names (nested TOML sections)" do
      config = %{"plugins.transcribe_whisper" => %{"model" => "turbo", "timeout" => 600_000}}
      result = TomlEncoder.encode(config)
      assert result =~ "[plugins.transcribe_whisper]"
      assert result =~ ~s(model = "turbo")
      assert result =~ "timeout = 600000"
    end

    test "round-trips through TOML parser" do
      config = %{
        "worker" => %{"queue_general" => 5, "enabled" => true},
        "archive" => %{"path" => "/data/archive"}
      }

      encoded = TomlEncoder.encode(config)
      {:ok, parsed} = Toml.decode(encoded)

      assert parsed["worker"]["queue_general"] == 5
      assert parsed["worker"]["enabled"] == true
      assert parsed["archive"]["path"] == "/data/archive"
    end
  end
end
