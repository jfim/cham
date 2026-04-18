defmodule Cham.Pipeline.QueueScaler do
  @moduledoc """
  Manages Oban queue concurrency limits from the runtime TOML config.

  Queues boot at limit 0 in `config.exs` so that no jobs are dispatched
  until startup reconciliation has had a chance to run. Once this process
  starts it registers an `oban.queues` schema, scales each queue to its
  configured value, and re-scales when the config changes.
  """

  use GenServer
  require Logger

  alias Cham.Config.Events.ConfigChanged

  @namespace "oban.queues"

  @schema [
    %{
      key: :general,
      type: :integer,
      default: 5,
      description: "Concurrency for the general-purpose queue",
      required: false,
      options: nil
    },
    %{
      key: :network,
      type: :integer,
      default: 3,
      description: "Concurrency for the network-bound queue",
      required: false,
      options: nil
    },
    %{
      key: :gpu,
      type: :integer,
      default: 1,
      description: "Concurrency for the GPU-bound queue",
      required: false,
      options: nil
    },
    %{
      key: :subscriptions,
      type: :integer,
      default: 2,
      description: "Concurrency for the subscriptions polling queue",
      required: false,
      options: nil
    }
  ]

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def schema, do: @schema
  def namespace, do: @namespace

  @impl true
  def init(_opts) do
    case Cham.Config.Manager.register(@namespace, @schema) do
      :ok -> :ok
      {:error, :already_registered} -> :ok
    end

    Cham.EventBus.subscribe("config:#{@namespace}")
    apply_all()
    {:ok, %{}}
  end

  @impl true
  def handle_info(%ConfigChanged{namespace: @namespace}, state) do
    apply_all()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp apply_all do
    case Cham.Config.Manager.read_all(@namespace) do
      {:ok, values} ->
        Enum.each(values, fn {queue, limit} ->
          Oban.scale_queue(queue: queue, limit: limit)
        end)

      {:error, reason} ->
        Logger.warning("QueueScaler: failed to read queue config: #{inspect(reason)}")
    end
  end
end
