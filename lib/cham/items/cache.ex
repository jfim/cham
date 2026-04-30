defmodule Cham.Items.Cache do
  @moduledoc """
  Per-item memoization for derived display values (title, thumbnail) that would
  otherwise hit the DB and filesystem on every list render. Entries are
  invalidated by item and pipeline events so callers can treat cached values as
  authoritative without further checks.
  """

  use GenServer

  alias Cham.Items.Events.{ItemArchived, ItemDeleted, ItemStatusChanged}
  alias Cham.Pipeline.Events.StageCompleted

  @table :cham_items_cache

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc """
  Returns the cached value for `item_id`, computing it via `fun` on miss.
  Lookup and insert happen in the calling process — no GenServer round-trip.
  """
  def fetch(item_id, fun) when is_function(fun, 0) do
    case :ets.lookup(@table, item_id) do
      [{^item_id, value}] ->
        value

      [] ->
        value = fun.()
        :ets.insert(@table, {item_id, value})
        value
    end
  end

  def invalidate(item_id), do: :ets.delete(@table, item_id)

  def clear, do: :ets.delete_all_objects(@table)

  @impl true
  def init(:ok) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    Cham.EventBus.subscribe("item")
    Cham.EventBus.subscribe("pipeline")
    {:ok, %{}}
  end

  @impl true
  def handle_info(%ItemDeleted{item_id: id}, state), do: drop(id, state)
  def handle_info(%ItemArchived{item_id: id}, state), do: drop(id, state)
  def handle_info(%ItemStatusChanged{item_id: id}, state), do: drop(id, state)
  def handle_info(%StageCompleted{item_id: id}, state), do: drop(id, state)
  def handle_info(%{item: %Cham.Items.Item{id: id}}, state), do: drop(id, state)
  def handle_info(_other, state), do: {:noreply, state}

  defp drop(id, state) do
    :ets.delete(@table, id)
    {:noreply, state}
  end
end
