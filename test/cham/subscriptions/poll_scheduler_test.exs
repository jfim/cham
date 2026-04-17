defmodule Cham.Subscriptions.PollSchedulerTest do
  use Cham.DataCase, async: false
  use Oban.Testing, repo: Cham.Repo

  alias Cham.Subscriptions
  alias Cham.Subscriptions.{PollScheduler, PollWorker}

  test "enqueues a PollWorker job for each due subscription" do
    {:ok, due} =
      Subscriptions.create_subscription(%{
        source_url: "https://due.example/feed",
        backend: "cham_rss",
        title: "Due",
        poll_interval_seconds: 3600
      })

    {:ok, _} =
      Subscriptions.update_subscription(due, %{
        last_polled_at: DateTime.add(DateTime.utc_now(), -7200, :second)
      })

    {:ok, fresh} =
      Subscriptions.create_subscription(%{
        source_url: "https://fresh.example/feed",
        backend: "cham_rss",
        title: "Fresh",
        poll_interval_seconds: 3600
      })

    {:ok, _} = Subscriptions.update_subscription(fresh, %{last_polled_at: DateTime.utc_now()})

    assert :ok = perform_job(PollScheduler, %{})

    assert_enqueued(worker: PollWorker, args: %{"subscription_id" => due.id})
    refute_enqueued(worker: PollWorker, args: %{"subscription_id" => fresh.id})
  end
end
