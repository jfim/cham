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
