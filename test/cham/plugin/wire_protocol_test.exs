defmodule Cham.Plugin.WireProtocolTest do
  use ExUnit.Case, async: true
  alias Cham.Plugin.WireProtocol

  alias Cham.Plugin.WireProtocol.{
    PerformRequest,
    CanProcessRequest,
    SubscriptionRequest,
    Input,
    StageResult,
    SubscriptionResult
  }

  describe "encode_request/1" do
    test "encodes a stage perform request" do
      req = %PerformRequest{
        item_id: "item-1",
        config: %{"min_words" => 20},
        inputs: [
          %Input{
            type: "html_capture",
            labels: %{"origin" => "original"},
            filenames: ["page.html"],
            input_path: "inputs"
          }
        ]
      }

      assert %{
               "request" => "perform",
               "item_id" => "item-1",
               "config" => %{"min_words" => 20},
               "inputs" => [
                 %{
                   "type" => "html_capture",
                   "labels" => %{"origin" => "original"},
                   "filenames" => ["page.html"],
                   "input_path" => "inputs"
                 }
               ]
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
        "artifacts" => [
          %{
            "type" => "article_markdown",
            "labels" => %{"format" => "text"},
            "filenames" => ["content.md"]
          }
        ],
        "item_metadata" => %{"title" => "Hi"},
        "provenance" => %{"tool" => "readability"}
      }

      assert {:ok, %StageResult{outcome: :produced} = r} = WireProtocol.decode_stage_result(json)

      assert [
               %{
                 type: "article_markdown",
                 labels: %{"format" => "text"},
                 filenames: ["content.md"]
               }
             ] =
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
