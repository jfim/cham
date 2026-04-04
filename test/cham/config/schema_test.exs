defmodule Cham.Config.SchemaTest do
  use ExUnit.Case, async: true

  alias Cham.Config.Schema

  @schema [
    %{key: :name, type: :string, default: "default", description: "A name"},
    %{key: :count, type: :integer, default: 5, description: "A count"},
    %{key: :rate, type: :float, default: 1.0, description: "A rate"},
    %{key: :enabled, type: :boolean, default: true, description: "Enabled flag"},
    %{key: :mode, type: :string, default: "fast", description: "Mode", options: ["fast", "slow"]}
  ]

  describe "validate/2" do
    test "accepts valid values" do
      values = %{
        "name" => "hello",
        "count" => 10,
        "rate" => 2.5,
        "enabled" => false,
        "mode" => "slow"
      }

      assert {:ok, validated} = Schema.validate(values, @schema)
      assert validated == %{name: "hello", count: 10, rate: 2.5, enabled: false, mode: "slow"}
    end

    test "applies defaults for missing keys" do
      assert {:ok, validated} = Schema.validate(%{}, @schema)
      assert validated == %{name: "default", count: 5, rate: 1.0, enabled: true, mode: "fast"}
    end

    test "applies defaults for subset of keys" do
      values = %{"name" => "custom"}
      assert {:ok, validated} = Schema.validate(values, @schema)
      assert validated.name == "custom"
      assert validated.count == 5
    end

    test "rejects invalid type for integer" do
      values = %{"count" => "not_a_number"}
      assert {:error, errors} = Schema.validate(values, @schema)
      assert Enum.any?(errors, &String.contains?(&1, "count"))
    end

    test "rejects invalid type for boolean" do
      values = %{"enabled" => "yes"}
      assert {:error, errors} = Schema.validate(values, @schema)
      assert Enum.any?(errors, &String.contains?(&1, "enabled"))
    end

    test "rejects value not in options list" do
      values = %{"mode" => "turbo"}
      assert {:error, errors} = Schema.validate(values, @schema)
      assert Enum.any?(errors, &String.contains?(&1, "mode"))
    end

    test "accepts integer where float is expected" do
      values = %{"rate" => 3}
      assert {:ok, validated} = Schema.validate(values, @schema)
      assert validated.rate == 3.0
    end

    test "ignores unknown keys" do
      values = %{"name" => "hello", "unknown_key" => "ignored"}
      assert {:ok, validated} = Schema.validate(values, @schema)
      refute Map.has_key?(validated, :unknown_key)
    end
  end
end
