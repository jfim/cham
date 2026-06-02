defmodule Cham.PluginFixtures.FakeStage do
  @moduledoc false
  @behaviour Cham.Plugin.Stage
  alias Cham.Plugin.{Manifest, WireProtocol}

  @impl true
  def manifest do
    %Manifest{
      id: "fake_stage",
      kind: :stage,
      phase: :extract,
      version: 1,
      inputs: [%{type: "html_capture", labels: %{}}],
      outputs: [%{type: "article_markdown", labels: %{}}],
      declares_types: ["article_markdown"],
      class: :in_process,
      source: {:module, __MODULE__}
    }
  end

  @impl true
  def perform(%WireProtocol.PerformRequest{item_id: item_id}, emit) do
    emit.(%{event: "status", message: "working on #{item_id}"})

    %WireProtocol.StageResult{
      outcome: :produced,
      artifacts: [%{type: "article_markdown", labels: %{}, filenames: ["content.md"]}],
      item_metadata: %{"title" => "Faked"},
      provenance: %{"tool" => "fake"}
    }
  end

  @impl true
  def can_process(%WireProtocol.CanProcessRequest{inputs: inputs}), do: inputs != []
end
