defmodule Cham.Subscriptions.Backends.RSS do
  @moduledoc """
  Subscription backend that polls an RSS/Atom feed and returns its entries as
  ingestable items.
  """
  @behaviour Cham.Subscriptions.Backend

  alias Cham.Subscriptions.RssParser

  @impl true
  def id, do: :cham_rss

  @impl true
  def name, do: "RSS/Atom"

  @impl true
  def config_schema do
    [
      %{
        key: :user_agent,
        type: :string,
        default: "Cham Subscriptions/1.0",
        description: "User-Agent header used when fetching feeds",
        required: false,
        options: nil
      }
    ]
  end

  @impl true
  def stream_pages(url) do
    Stream.resource(
      fn -> :start end,
      fn
        :start ->
          case fetch_and_parse(url) do
            {:ok, entries} -> {[entries], :done}
            {:error, reason} -> raise "RSS fetch failed: #{inspect(reason)}"
          end

        :done ->
          {:halt, :done}
      end,
      fn _ -> :ok end
    )
  end

  defp fetch_and_parse(url) do
    ua = user_agent()

    case Req.get(url, headers: [{"user-agent", ua}]) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        body_str = if is_binary(body), do: body, else: IO.iodata_to_binary(body)

        case RssParser.parse(body_str) do
          {:ok, %{entries: entries}} -> {:ok, entries}
          {:error, _} = err -> err
        end

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @default_user_agent "Cham Subscriptions/1.0"
  @config_namespace "subscriptions.cham_rss"

  defp user_agent do
    case Cham.Config.Manager.read_all(@config_namespace) do
      {:ok, %{user_agent: v}} when is_binary(v) and v != "" -> v
      _ -> @default_user_agent
    end
  rescue
    _ -> @default_user_agent
  end
end
