defmodule Cham.PluginFixtures.RaisingStage do
  @moduledoc false
  @behaviour Cham.Plugin.Stage
  alias Cham.Plugin.WireProtocol

  @impl true
  def manifest, do: raise("boom in manifest/0")

  @impl true
  def perform(%WireProtocol.PerformRequest{}, _emit),
    do: %WireProtocol.StageResult{outcome: :not_applicable}
end
