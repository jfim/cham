defmodule ChamWeb.ItemController do
  use ChamWeb, :controller

  alias Cham.Items
  alias Cham.Pipeline

  action_fallback :handle_error

  def create(conn, %{"url" => url} = params) do
    tags = Map.get(params, "tags", [])

    case Pipeline.submit_url(url, tags: tags) do
      {:ok, item} ->
        conn
        |> put_status(:accepted)
        |> put_view(ChamWeb.ItemJSON)
        |> render("show.json", item: item)

      {:error, %Ecto.Changeset{} = changeset} ->
        if unique_constraint_violation?(changeset) do
          conn
          |> put_status(:conflict)
          |> put_view(ChamWeb.ItemJSON)
          |> render("error.json", error: "URL already exists")
        else
          message = format_changeset_errors(changeset)

          conn
          |> put_status(:unprocessable_entity)
          |> put_view(ChamWeb.ItemJSON)
          |> render("error.json", error: message)
        end
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(ChamWeb.ItemJSON)
    |> render("error.json", error: "url is required")
  end

  def index(conn, params) do
    filters =
      []
      |> maybe_add_filter(:status, params["status"])
      |> maybe_add_filter(:content_type, params["content_type"])
      |> maybe_add_filter(:tag, params["tag"])

    items = Items.list_items(filters)

    conn
    |> put_view(ChamWeb.ItemJSON)
    |> render("index.json", items: items)
  end

  def show(conn, %{"id" => id}) do
    case Items.get_item_by_slug_or_id(id) do
      {:ok, item} ->
        conn
        |> put_view(ChamWeb.ItemJSON)
        |> render("show.json", item: item)

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> put_view(ChamWeb.ItemJSON)
        |> render("error.json", error: "not found")
    end
  end

  defp unique_constraint_violation?(%Ecto.Changeset{} = changeset) do
    Enum.any?(changeset.errors, fn
      {:url, {_, opts}} -> Keyword.get(opts, :constraint) == :unique
      _ -> false
    end)
  end

  defp format_changeset_errors(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map_join(", ", fn {field, errors} ->
      "#{field} #{Enum.join(errors, ", ")}"
    end)
  end

  defp maybe_add_filter(filters, _key, nil), do: filters
  defp maybe_add_filter(filters, _key, ""), do: filters
  defp maybe_add_filter(filters, key, value), do: [{key, value} | filters]

  defp handle_error(conn, _reason) do
    conn
    |> put_status(:internal_server_error)
    |> put_view(ChamWeb.ItemJSON)
    |> render("error.json", error: "internal server error")
  end
end
