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

  def decode_stage_result(%{"outcome" => "failed"}),
    do: {:error, "failed outcome is missing required category"}

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
    case Enum.find(@failure_categories, fn c -> Atom.to_string(c) == str end) do
      nil -> :error
      atom -> {:ok, atom}
    end
  end
end
