defmodule Cham.Subscriptions.IntegrationTest do
  use Cham.DataCase, async: false
  use Oban.Testing, repo: Cham.Repo

  import Ecto.Query

  @moduletag :integration

  alias Cham.Repo
  alias Cham.Subscriptions
  alias Cham.Subscriptions.{BackendRegistry, PollWorker, PollScheduler}
  alias Cham.Subscriptions.Backends.RSS
  alias Cham.Items.Item

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "subs_integration_test_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    Application.put_env(:cham, :archive_root, tmp)
    on_exit(fn -> Application.delete_env(:cham, :archive_root) end)

    case Process.whereis(Cham.Subscriptions.BackendRegistry) do
      nil -> {:ok, _} = start_supervised({BackendRegistry, []})
      _ -> :ok
    end

    :ok = BackendRegistry.register(RSS)

    bypass = Bypass.open()
    {:ok, bypass: bypass, base: "http://localhost:#{bypass.port}"}
  end

  defp rss_xml(items) do
    body =
      items
      |> Enum.map(fn {id, title, date} ->
        """
        <item>
          <title>#{title}</title>
          <link>https://example.com/#{id}</link>
          <guid>#{id}</guid>
          <pubDate>#{date}</pubDate>
        </item>
        """
      end)
      |> Enum.join("\n")

    """
    <?xml version="1.0"?>
    <rss version="2.0"><channel>
      <title>Integration Feed</title>
      <description>end to end</description>
      <link>https://example.com</link>
      #{body}
    </channel></rss>
    """
  end

  test "scheduler → worker → feed fetch → item creation", %{bypass: bypass, base: base} do
    Bypass.expect(bypass, "GET", "/feed.xml", fn conn ->
      body =
        rss_xml([
          {"two", "Two", "Mon, 14 Apr 2026 12:00:00 +0000"},
          {"one", "One", "Sun, 13 Apr 2026 12:00:00 +0000"}
        ])

      conn
      |> Plug.Conn.put_resp_content_type("application/rss+xml")
      |> Plug.Conn.resp(200, body)
    end)

    {:ok, sub} =
      Subscriptions.create_subscription(%{
        source_url: "#{base}/feed.xml",
        backend: "cham_rss",
        title: "Integration",
        poll_interval_seconds: 3600
      })

    {:ok, _} =
      Subscriptions.update_subscription(sub, %{
        last_polled_at: DateTime.add(DateTime.utc_now(), -7200, :second)
      })

    assert :ok = perform_job(PollScheduler, %{})
    assert_enqueued(worker: PollWorker, args: %{"subscription_id" => sub.id})

    assert :ok = perform_job(PollWorker, %{"subscription_id" => sub.id})

    items = Repo.all(from i in Item, where: i.subscription_id == ^sub.id, order_by: [asc: i.source_item_id])

    ids = Enum.map(items, & &1.source_item_id)
    assert "one" in ids
    assert "two" in ids

    sub = Repo.reload!(sub)
    assert sub.consecutive_failures == 0
    assert sub.last_error == nil
    assert sub.last_polled_at != nil
  end
end
