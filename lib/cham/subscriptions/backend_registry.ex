defmodule Cham.Subscriptions.BackendRegistry do
  use GenServer

  @default_name __MODULE__

  def start_link(opts) do
    name = Keyword.get(opts, :name, @default_name)
    GenServer.start_link(__MODULE__, :ok, name: name)
  end

  def register(server \\ @default_name, module) do
    GenServer.call(server, {:register, module})
  end

  def lookup(server \\ @default_name, id) when is_atom(id) do
    GenServer.call(server, {:lookup, id})
  end

  def list(server \\ @default_name) do
    GenServer.call(server, :list)
  end

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:register, module}, _from, state) do
    id = module.id()
    {:reply, :ok, Map.put(state, id, module)}
  end

  def handle_call({:lookup, id}, _from, state) do
    case Map.fetch(state, id) do
      {:ok, m} -> {:reply, {:ok, m}, state}
      :error -> {:reply, :error, state}
    end
  end

  def handle_call(:list, _from, state) do
    {:reply, Map.values(state), state}
  end
end
