defmodule Cham.Plugins.GenericDownloadUrl do
  @behaviour Cham.Plugin

  @impl true
  def plugin_id, do: "generic_download_url"

  @impl true
  def name, do: "Generic URL Downloader"

  @impl true
  def description, do: "Fallback HTTP downloader that matches any URL"

  @impl true
  def config_schema do
    [
      %{
        key: :timeout,
        type: :integer,
        default: 300_000,
        description: "Request timeout in milliseconds",
        required: false,
        options: nil
      },
      %{
        key: :max_body_size,
        type: :integer,
        default: 524_288_000,
        description: "Maximum download size in bytes",
        required: false,
        options: nil
      },
      %{
        key: :passepartout_fallback,
        type: :boolean,
        default: false,
        description: "Fall back to passe-partout (headless browser proxy) on 4xx responses",
        required: false,
        options: nil
      },
      %{
        key: :passepartout_host,
        type: :url,
        default: "",
        description: "Passe-partout host URL (e.g. http://localhost:8000)",
        required: false,
        options: nil
      },
      %{
        key: :passepartout_token,
        type: :string,
        default: "",
        description: "Passe-partout bearer token (optional)",
        required: false,
        options: nil
      }
    ]
  end

  @impl true
  def init(_context) do
    Cham.Config.Manager.register("plugins.generic_download_url", config_schema())
    {:ok, %{}}
  end

  @impl true
  def stages(_state), do: [__MODULE__.DownloadStage]
end

defmodule Cham.Plugins.GenericDownloadUrl.DownloadStage do
  @behaviour Cham.Stage

  @default_timeout 300_000
  @default_max_body_size 524_288_000

  @impl true
  def name, do: "Download URL"

  @impl true
  def description, do: "Downloads a URL via HTTP"

  @impl true
  def input_matchers, do: [%{}]

  @impl true
  def output_labels, do: [%{"origin" => "original", "type" => "initial_download"}]

  @impl true
  def queue, do: :network

  @impl true
  def max_attempts, do: 3

  @impl true
  def can_process?(_current_artifacts), do: :not_applicable

  @impl true
  def perform(inputs, working_dir, desired, item_id) do
    config = load_config()
    perform(inputs, working_dir, desired, item_id, config)
  end

  @doc """
  Testable variant that accepts config directly.
  """
  def perform(_inputs, working_dir, _desired, item_id, config) do
    timeout = Map.get(config, :timeout, @default_timeout)
    max_body_size = Map.get(config, :max_body_size, @default_max_body_size)

    item = Cham.Items.get_item!(item_id)
    url = item.url

    # HEAD check: enforce size limits if HEAD succeeds, skip if server doesn't support HEAD
    case head_check(url, timeout, max_body_size) do
      {:ok, content_type, content_length} ->
        do_download(url, working_dir, content_type, content_length, timeout, config)

      {:error, :too_large, message} ->
        {:error, message}

      {:error, _reason} ->
        # HEAD failed (server doesn't support it, etc.) — proceed with GET
        do_download(url, working_dir, nil, nil, timeout, config)
    end
  end

  defp do_download(url, working_dir, content_type_hint, content_length, timeout, config) do
    ext = extension_from(content_type_hint || "application/octet-stream", url)
    filename = "original#{ext}"
    dest = Path.join(working_dir, filename)

    case stream_download(url, dest, timeout) do
      {:ok, response_content_type} ->
        content_type = content_type_hint || response_content_type || "application/octet-stream"
        success(filename, content_type, content_length)

      {:error, {:http_status, status}} ->
        if status in 400..499 and passepartout_enabled?(config) do
          passepartout_fallback(url, working_dir, timeout, config)
        else
          {:error, "HTTP GET returned status #{status}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp success(filename, content_type, content_length) do
    {:ok,
     %{
       artifacts: [
         %{
           labels: %{
             "origin" => "original",
             "type" => "initial_download",
             "content_type" => content_type
           },
           filenames: [filename]
         }
       ],
       item_metadata: %{
         "content_type" => content_type,
         "content_length" => content_length
       },
       provenance: %{}
     }}
  end

  defp passepartout_enabled?(config) do
    Map.get(config, :passepartout_fallback, false) and
      is_binary(Map.get(config, :passepartout_host, "")) and
      Map.get(config, :passepartout_host, "") != ""
  end

  defp passepartout_fallback(url, working_dir, timeout, config) do
    host = config |> Map.get(:passepartout_host, "") |> String.trim_trailing("/")
    token = Map.get(config, :passepartout_token, "")

    headers =
      [{"content-type", "application/json"}] ++
        if token != "", do: [{"authorization", "Bearer #{token}"}], else: []

    case Req.post("#{host}/fetch",
           json: %{url: url},
           headers: headers,
           receive_timeout: timeout,
           connect_options: [timeout: timeout],
           retry: false
         ) do
      {:ok, %{status: 200, body: %{"html" => html} = body}} when is_binary(html) ->
        filename = "original.html"
        dest = Path.join(working_dir, filename)
        File.write!(dest, html)
        upstream_status = Map.get(body, "status")
        content_type = "text/html"

        result = success(filename, content_type, byte_size(html))

        case result do
          {:ok, map} ->
            {:ok,
             put_in(map, [:provenance, :passepartout], %{
               "fallback" => true,
               "upstream_status" => upstream_status,
               "final_url" => Map.get(body, "final_url")
             })}

          other ->
            other
        end

      {:ok, %{status: status, body: body}} ->
        {:error, "passe-partout fallback returned status #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, "passe-partout fallback failed: #{inspect(reason)}"}
    end
  end

  defp head_check(url, timeout, max_body_size) do
    case Req.head(url,
           receive_timeout: timeout,
           connect_options: [timeout: timeout],
           retry: false
         ) do
      {:ok, %{status: status} = resp} when status in 200..299 ->
        content_length = parse_content_length(resp.headers["content-length"])
        content_type = parse_content_type(resp.headers["content-type"])

        if content_length && content_length > max_body_size do
          {:error, :too_large,
           "Content too large: #{content_length} bytes exceeds limit of #{max_body_size} bytes"}
        else
          {:ok, content_type, content_length}
        end

      {:ok, %{status: status}} ->
        {:error, "HTTP HEAD returned status #{status}"}

      {:error, reason} ->
        {:error, "HTTP HEAD failed: #{inspect(reason)}"}
    end
  end

  defp stream_download(url, dest, timeout) do
    case Req.get(url,
           into: File.stream!(dest),
           receive_timeout: timeout,
           connect_options: [timeout: timeout],
           retry: false
         ) do
      {:ok, %{status: status} = resp} when status in 200..299 ->
        content_type = parse_content_type(resp.headers["content-type"])
        {:ok, content_type}

      {:ok, %{status: status}} ->
        File.rm(dest)
        {:error, {:http_status, status}}

      {:error, reason} ->
        File.rm(dest)
        {:error, "HTTP GET failed: #{inspect(reason)}"}
    end
  end

  defp parse_content_length(nil), do: nil
  defp parse_content_length([]), do: nil

  defp parse_content_length([value | _]) do
    case Integer.parse(value) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_content_type(nil), do: "application/octet-stream"
  defp parse_content_type([]), do: "application/octet-stream"

  defp parse_content_type([value | _]) do
    value
    |> String.split(";")
    |> List.first()
    |> String.trim()
  end

  defp extension_from(content_type, url) do
    ext_from_mime(content_type) || ext_from_url(url) || ".bin"
  end

  defp ext_from_mime("text/html"), do: ".html"
  defp ext_from_mime("text/plain"), do: ".txt"
  defp ext_from_mime("application/pdf"), do: ".pdf"
  defp ext_from_mime("application/json"), do: ".json"
  defp ext_from_mime("image/jpeg"), do: ".jpg"
  defp ext_from_mime("image/png"), do: ".png"
  defp ext_from_mime("image/gif"), do: ".gif"
  defp ext_from_mime("image/webp"), do: ".webp"
  defp ext_from_mime("audio/mpeg"), do: ".mp3"
  defp ext_from_mime("audio/ogg"), do: ".ogg"
  defp ext_from_mime("video/mp4"), do: ".mp4"
  defp ext_from_mime("video/webm"), do: ".webm"
  defp ext_from_mime("application/octet-stream"), do: nil
  defp ext_from_mime(_), do: nil

  defp ext_from_url(url) do
    path =
      url
      |> URI.parse()
      |> Map.get(:path, "")

    case Path.extname(path || "") do
      "" -> nil
      ext -> ext
    end
  end

  defp load_config do
    Cham.Plugin.Config.read("generic_download_url")
  end
end
