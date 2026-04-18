defmodule ChamWeb.TagController do
  use ChamWeb, :controller

  alias Cham.Items

  def clear(conn, params) do
    opts =
      case Map.get(params, "content_type") do
        nil -> []
        "" -> []
        ct -> [content_type: ct]
      end

    count = Items.clear_tags(opts)

    json(conn, %{cleared: count})
  end
end
