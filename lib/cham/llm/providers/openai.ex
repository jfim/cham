defmodule Cham.LLM.Providers.OpenAI do
  @behaviour Cham.LLM.Provider

  @impl true
  def chat(messages, opts) do
    model = Keyword.fetch!(opts, :model)
    url = Keyword.get(opts, :url, "http://localhost:11434")
    timeout = Keyword.get(opts, :timeout, 300_000)
    api_key = Keyword.get(opts, :api_key)

    headers = [{"content-type", "application/json"}]
    headers = if api_key, do: [{"authorization", "Bearer #{api_key}"} | headers], else: headers

    body = Jason.encode!(%{"model" => model, "messages" => messages})

    endpoint =
      if String.ends_with?(url, "/v1"),
        do: "#{url}/chat/completions",
        else: "#{url}/v1/chat/completions"

    case Req.post(endpoint,
           body: body,
           headers: headers,
           receive_timeout: timeout,
           connect_options: [timeout: 10_000],
           retry: false
         ) do
      {:ok, %{status: 200, body: resp_body}} ->
        parse_response(resp_body)

      {:ok, %{status: status, body: resp_body}} ->
        body_str = if is_binary(resp_body), do: resp_body, else: Jason.encode!(resp_body)
        {:error, "HTTP #{status}: #{body_str}"}

      {:error, exception} ->
        {:error, "request failed: #{inspect(exception)}"}
    end
  end

  defp parse_response(%{"choices" => [%{"message" => %{"content" => content}} | _]}),
    do: {:ok, strip_thinking(content)}

  defp strip_thinking(text) when is_binary(text) do
    text
    |> String.replace(~r/<think>[\s\S]*?<\/think>/m, "")
    |> String.trim()
  end

  defp strip_thinking(text), do: text

  defp parse_response(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> parse_response(decoded)
      {:error, _} -> {:error, "failed to parse response"}
    end
  end

  defp parse_response(_), do: {:error, "failed to parse response"}
end
