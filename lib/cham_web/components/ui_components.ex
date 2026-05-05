defmodule ChamWeb.UIComponents do
  @moduledoc """
  Shared UI components for Cham v2.

  Provides reusable function components for badges, timestamps, content
  availability states, progress bars, and tag pills.
  """
  use Phoenix.Component

  @doc """
  Renders a colored badge for content types.

  ## Examples

      <.content_type_badge type="article" />
      <.content_type_badge type="video" />
  """
  attr :type, :string, required: true

  def content_type_badge(assigns) do
    {label, variant} =
      case assigns.type do
        "article" -> {"article", "is-article"}
        "video" -> {"video", "is-video"}
        "document" -> {"pdf", "is-pdf"}
        "podcast" -> {"podcast", "is-audio"}
        "feed" -> {"feed", "is-article"}
        nil -> {"unknown", "is-article"}
        _ -> {"unknown", "is-article"}
      end

    assigns = assign(assigns, label: label, variant: variant)

    ~H"""
    <span class={"type-badge #{@variant}"}>
      <span class="dot"></span>
      {@label}
    </span>
    """
  end

  @doc """
  Renders a colored badge for item and stage execution statuses.

  ## Examples

      <.status_badge status="complete" />
      <.status_badge status="processing" />
  """
  attr :status, :string, required: true

  def status_badge(assigns) do
    {label, color} =
      case assigns.status do
        "bootstrapping" -> {"Bootstrapping", "bg-blue-100 text-blue-800"}
        "processing" -> {"Processing", "bg-amber-100 text-amber-800"}
        "complete" -> {"Complete", "bg-green-100 text-green-800"}
        "incomplete" -> {"Incomplete", "bg-yellow-100 text-yellow-800"}
        "failed" -> {"Failed", "bg-red-100 text-red-800"}
        "crashed" -> {"Crashed", "bg-red-100 text-red-800"}
        "started" -> {"Started", "bg-blue-100 text-blue-800"}
        "completed" -> {"Completed", "bg-green-100 text-green-800"}
        "snoozed" -> {"Snoozed", "bg-yellow-100 text-yellow-800"}
        other -> {other, "bg-gray-100 text-gray-800"}
      end

    assigns = assign(assigns, label: label, color: color)

    ~H"""
    <span class={"inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium #{@color}"}>
      {@label}
    </span>
    """
  end

  @doc """
  Renders a colored badge for pipeline stage names.

  ## Examples

      <.stage_badge stage="download_file" />
      <.stage_badge stage="transcribe_audio" />
  """
  attr :stage, :string, required: true

  def stage_badge(assigns) do
    color =
      cond do
        String.starts_with?(assigns.stage, "download") -> "bg-blue-100 text-blue-800"
        String.starts_with?(assigns.stage, "transcribe") -> "bg-purple-100 text-purple-800"
        String.starts_with?(assigns.stage, "summarize") -> "bg-amber-100 text-amber-800"
        true -> "bg-gray-100 text-gray-800"
      end

    label =
      assigns.stage
      |> String.replace("_", " ")
      |> String.split(" ")
      |> Enum.map(&String.capitalize/1)
      |> Enum.join(" ")

    assigns = assign(assigns, label: label, color: color)

    ~H"""
    <span class={"inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium #{@color}"}>
      {@label}
    </span>
    """
  end

  @doc """
  Renders a relative time element.

  ## Examples

      <.relative_time at={@item.inserted_at} />
  """
  attr :at, :any, required: true

  def relative_time(assigns) do
    now = DateTime.utc_now()

    diff_seconds =
      case assigns.at do
        %DateTime{} = dt -> DateTime.diff(now, dt)
        _ -> 0
      end

    display =
      cond do
        diff_seconds < 60 -> "just now"
        diff_seconds < 3600 -> "#{div(diff_seconds, 60)}m ago"
        diff_seconds < 86_400 -> "#{div(diff_seconds, 3600)}h ago"
        diff_seconds < 2_592_000 -> "#{div(diff_seconds, 86_400)}d ago"
        true -> format_date(assigns.at)
      end

    iso =
      case assigns.at do
        %DateTime{} = dt -> DateTime.to_iso8601(dt)
        _ -> ""
      end

    title = format_date(assigns.at)

    assigns = assign(assigns, display: display, iso: iso, title: title)

    ~H"""
    <time datetime={@iso} title={@title}>{@display}</time>
    """
  end

  defp format_date(%DateTime{} = dt) do
    month =
      case dt.month do
        1 -> "Jan"
        2 -> "Feb"
        3 -> "Mar"
        4 -> "Apr"
        5 -> "May"
        6 -> "Jun"
        7 -> "Jul"
        8 -> "Aug"
        9 -> "Sep"
        10 -> "Oct"
        11 -> "Nov"
        12 -> "Dec"
      end

    "#{month} #{dt.day}, #{dt.year}"
  end

  defp format_date(_), do: ""

  @doc """
  Renders a tag pill with optional count.

  ## Examples

      <.tag_pill tag="elixir" />
      <.tag_pill tag="elixir" count={42} active={true} />
  """
  attr :tag, :string, required: true
  attr :count, :integer, default: nil
  attr :active, :boolean, default: false
  attr :rest, :global

  def tag_pill(assigns) do
    base_class =
      "inline-flex items-center gap-1 rounded-full px-2.5 py-0.5 text-xs font-medium cursor-pointer"

    color_class =
      if assigns.active do
        "bg-indigo-100 text-indigo-800 ring-1 ring-indigo-300"
      else
        "bg-gray-100 text-gray-700"
      end

    assigns = assign(assigns, class: "#{base_class} #{color_class}")

    ~H"""
    <span class={@class} {@rest}>
      {@tag}{if @count, do: " "}<span
        :if={@count}
        class="text-gray-400"
      ><%= @count %></span>
    </span>
    """
  end

  @doc """
  Renders a progress bar with optional message.

  ## Examples

      <.progress_bar progress={0.75} />
      <.progress_bar progress={0.5} message="Processing..." />
  """
  attr :progress, :float, required: true
  attr :message, :string, default: nil

  def progress_bar(assigns) do
    pct = min(max(assigns.progress * 100, 0), 100)
    assigns = assign(assigns, pct: pct)

    ~H"""
    <div class="w-full">
      <div class="flex items-center justify-between mb-1">
        <span :if={@message} class="text-xs text-gray-500">{@message}</span>
        <span class="text-xs text-gray-500 ml-auto">{Float.round(@pct, 0) |> trunc()}%</span>
      </div>
      <div class="w-full bg-gray-200 rounded-full h-1.5">
        <div
          class="bg-indigo-600 h-1.5 rounded-full transition-all duration-300"
          style={"width: #{@pct}%"}
        >
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders a content availability state.

  ## Examples

      <.content_state state={:available}>
        <p>Content here</p>
      </.content_state>

      <.content_state state={:processing} />
      <.content_state state={:failed} error="Something went wrong" />
      <.content_state state={:not_requested} />
  """
  attr :state, :atom, required: true
  attr :error, :string, default: nil
  slot :inner_block

  def content_state(assigns) do
    ~H"""
    <%= case @state do %>
      <% :available -> %>
        {render_slot(@inner_block)}
      <% :processing -> %>
        <div class="flex items-center gap-2 text-sm text-gray-500">
          <svg
            class="animate-spin h-5 w-5"
            xmlns="http://www.w3.org/2000/svg"
            fill="none"
            viewBox="0 0 24 24"
          >
            <circle
              class="opacity-25"
              cx="12"
              cy="12"
              r="10"
              stroke="currentColor"
              stroke-width="4"
            />
            <path
              class="opacity-75"
              fill="currentColor"
              d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"
            />
          </svg>
          <span>Currently being generated...</span>
        </div>
      <% :failed -> %>
        <div class="text-sm text-red-600">
          <span>Generation failed</span>
          <span :if={@error} class="ml-1 text-red-500">{@error}</span>
        </div>
      <% :not_requested -> %>
        <span class="text-sm text-gray-400">Not available for this item</span>
      <% :not_loaded -> %>
        <span class="text-sm text-gray-400">Loading…</span>
      <% _ -> %>
        <span class="text-sm text-gray-400">Not available for this item</span>
    <% end %>
    """
  end

  @doc """
  Extracts the host from a URL string.

  ## Examples

      iex> ChamWeb.UIComponents.domain_from_url("https://example.com/path")
      "example.com"

      iex> ChamWeb.UIComponents.domain_from_url(nil)
      ""
  """
  def domain_from_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) -> host
      _ -> ""
    end
  end

  def domain_from_url(_), do: ""

  @doc """
  Minimal navigation sidebar used on pages other than the dashboard
  (subscriptions, settings, item detail fallback, etc.). Matches the
  visual frame of the dashboard sidebar without the item-filter controls.

  ## Example

      <.nav_sidebar active={:subscriptions} />
  """
  attr :active, :atom,
    default: nil,
    doc: "which link to highlight (:subscriptions | :settings | nil)"

  use Phoenix.VerifiedRoutes, endpoint: ChamWeb.Endpoint, router: ChamWeb.Router

  def nav_sidebar(assigns) do
    ~H"""
    <aside class="w-64 shrink-0 bg-white border-r border-gray-200 flex flex-col">
      <div class="px-4 py-5 border-b border-gray-100">
        <.link navigate={~p"/"} class="text-xl font-bold text-indigo-600 hover:text-indigo-500">
          Cham
        </.link>
      </div>

      <div class="px-4 py-3 border-b border-gray-100">
        <.link
          navigate={~p"/"}
          class="flex items-center gap-2 px-2 py-1.5 rounded text-sm text-gray-600 hover:bg-gray-50"
        >
          <ChamWeb.CoreComponents.icon name="hero-home" class="h-4 w-4 text-gray-400" /> Dashboard
        </.link>
      </div>

      <div class="flex-1"></div>

      <div class="px-4 py-3 border-t border-gray-100 space-y-1">
        <.link
          navigate={~p"/subscriptions"}
          class={[
            "flex items-center gap-2 px-2 py-1.5 rounded text-sm hover:bg-gray-50",
            if(@active == :subscriptions,
              do: "bg-indigo-50 text-indigo-700 font-medium",
              else: "text-gray-600"
            )
          ]}
        >
          <ChamWeb.CoreComponents.icon name="hero-rss" class="h-4 w-4 text-gray-400" /> Subscriptions
        </.link>
        <.link
          navigate={~p"/config"}
          class={[
            "flex items-center gap-2 px-2 py-1.5 rounded text-sm hover:bg-gray-50",
            if(@active == :settings,
              do: "bg-indigo-50 text-indigo-700 font-medium",
              else: "text-gray-600"
            )
          ]}
        >
          <ChamWeb.CoreComponents.icon name="hero-cog-6-tooth" class="h-4 w-4 text-gray-400" />
          Settings
        </.link>
      </div>
    </aside>
    """
  end
end
