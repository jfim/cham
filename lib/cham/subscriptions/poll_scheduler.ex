defmodule Cham.Subscriptions.PollScheduler do
  use Oban.Worker, queue: :subscriptions, max_attempts: 1

  alias Cham.Subscriptions
  alias Cham.Subscriptions.PollWorker

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Subscriptions.list_due()
    |> Enum.each(fn sub ->
      %{"subscription_id" => sub.id}
      |> PollWorker.new()
      |> Oban.insert()
    end)

    :ok
  end
end
