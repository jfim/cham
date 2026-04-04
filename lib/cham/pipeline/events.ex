defmodule Cham.Pipeline.Events do
  defmodule StageStarted do
    @enforce_keys [:stage_id, :item_id]
    defstruct [:stage_id, :item_id, :attempt]
  end

  defmodule StageCompleted do
    @enforce_keys [:stage_id, :item_id]
    defstruct [:stage_id, :item_id, :duration_ms, metadata: %{}]
  end

  defmodule StageFailed do
    @enforce_keys [:stage_id, :item_id, :error]
    defstruct [:stage_id, :item_id, :error, :attempt]
  end

  defmodule StageSnoozed do
    @enforce_keys [:stage_id, :item_id, :duration_ms, :reason]
    defstruct [:stage_id, :item_id, :duration_ms, :reason]
  end

  defmodule StageProgress do
    @enforce_keys [:stage_id, :item_id]
    defstruct [:stage_id, :item_id, :progress, :message]
  end

  defmodule PipelineComplete do
    @enforce_keys [:item_id, :status]
    defstruct [:item_id, :status]
  end
end
