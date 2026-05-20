defmodule Cham.Items.StatsCache do
  @moduledoc """
  Process-wide cache for dashboard aggregate stats (type counts, tag counts,
  total visible item count). These are full-table aggregates that change only
  when items are mutated, so they're cheap to share across LiveView sessions
  and invalidate on any item event.
  """

  use GenServer

  alias Cham.Items
  alias Cham.Items.Events.{ItemArchived, ItemDeleted, ItemStatusChanged}
  alias Cham.Pipeline.Events.StageCompleted

  @table :cham_items_stats_cache
  @key :stats

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc """
  Returns `%{type_counts: ..., tag_counts: ..., total_count: ...}`.
  Computes and caches on miss; reads are a direct ETS lookup in the caller.
  """
  def stats do
    case :ets.lookup(@table, @key) do
      [{@key, value}] ->
        value

      [] ->
        value = compute()
        :ets.insert(@table, {@key, value})
        value
    end
  end

  def invalidate, do: :ets.delete(@table, @key)

  defp compute do
    %{
      type_counts: Items.count_by_content_type(),
      tag_counts: Items.count_by_tag(),
      total_count: Items.count_visible_items()
    }
  end

  @impl true
  def init(:ok) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    Cham.EventBus.subscribe("item")
    Cham.EventBus.subscribe("pipeline")
    {:ok, %{}}
  end

  @impl true
  def handle_info(%ItemDeleted{}, state), do: drop(state)
  def handle_info(%ItemArchived{}, state), do: drop(state)
  def handle_info(%ItemStatusChanged{}, state), do: drop(state)
  def handle_info(%StageCompleted{}, state), do: drop(state)
  def handle_info(%{item: %Cham.Items.Item{}}, state), do: drop(state)
  def handle_info(_other, state), do: {:noreply, state}

  defp drop(state) do
    :ets.delete(@table, @key)
    {:noreply, state}
  end
end
