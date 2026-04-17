defmodule ChamWeb.ItemController do
  use ChamWeb, :controller

  alias Cham.Items
  alias Cham.Pipeline

  action_fallback :handle_error

  def create(conn, %{"url" => url} = params) do
    case Cham.Subscriptions.get_by_source_url(url) do
      nil ->
        do_create(conn, url, params)

      sub ->
        conn
        |> put_status(:see_other)
        |> json(%{
          subscription_id: sub.id,
          redirect: "/subscriptions/#{sub.id}"
        })
    end
  end

  defp do_create(conn, url, params) do
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
        artifacts = Items.list_artifacts(item.id)
        stage_executions = Items.list_stage_executions(item.id)

        conn
        |> put_view(ChamWeb.ItemJSON)
        |> render("show_detail.json",
          item: item,
          artifacts: artifacts,
          stage_executions: stage_executions
        )

      {:error, :ambiguous} ->
        conn
        |> put_status(:conflict)
        |> put_view(ChamWeb.ItemJSON)
        |> render("error.json", error: "ambiguous id prefix; multiple items match")

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> put_view(ChamWeb.ItemJSON)
        |> render("error.json", error: "not found")
    end
  end

  def delete(conn, %{"id" => id} = params) do
    keep_files = params["keep_files"] == "true"

    case Items.get_item_by_slug_or_id(id) do
      {:ok, item} ->
        if item.status in ~w(bootstrapping processing) do
          Pipeline.cancel(item.id)
        end

        item = Items.get_item!(item.id)

        case Items.delete_item_with_files(item, keep_files: keep_files) do
          :ok ->
            send_resp(conn, :no_content, "")

          {:error, _} ->
            conn
            |> put_status(:internal_server_error)
            |> put_view(ChamWeb.ItemJSON)
            |> render("error.json", error: "failed to delete item")
        end

      {:error, :ambiguous} ->
        conn
        |> put_status(:conflict)
        |> put_view(ChamWeb.ItemJSON)
        |> render("error.json", error: "ambiguous id prefix; multiple items match")

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> put_view(ChamWeb.ItemJSON)
        |> render("error.json", error: "not found")
    end
  end

  def cancel(conn, %{"id" => id}) do
    case Items.get_item_by_slug_or_id(id) do
      {:ok, item} ->
        case Pipeline.cancel(item.id) do
          {:ok, updated} ->
            conn
            |> put_view(ChamWeb.ItemJSON)
            |> render("show.json", item: updated)

          {:error, :already_terminal} ->
            conn
            |> put_status(:conflict)
            |> put_view(ChamWeb.ItemJSON)
            |> render("error.json", error: "item is already in a terminal status")
        end

      {:error, :ambiguous} ->
        conn
        |> put_status(:conflict)
        |> put_view(ChamWeb.ItemJSON)
        |> render("error.json", error: "ambiguous id prefix; multiple items match")

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> put_view(ChamWeb.ItemJSON)
        |> render("error.json", error: "not found")
    end
  end

  def retry(conn, %{"id" => id} = params) do
    from_stage = params["from_stage"]

    case Items.get_item_by_slug_or_id(id) do
      {:ok, item} ->
        opts = [retry_failed: true]
        opts = if from_stage, do: Keyword.put(opts, :invalidate, [from_stage]), else: opts

        case Pipeline.reprocess(item.id, opts) do
          {:ok, updated} ->
            conn
            |> put_status(:accepted)
            |> put_view(ChamWeb.ItemJSON)
            |> render("show.json", item: updated)

          {:error, _} ->
            conn
            |> put_status(:unprocessable_entity)
            |> put_view(ChamWeb.ItemJSON)
            |> render("error.json", error: "failed to retry item")
        end

      {:error, :ambiguous} ->
        conn
        |> put_status(:conflict)
        |> put_view(ChamWeb.ItemJSON)
        |> render("error.json", error: "ambiguous id prefix; multiple items match")

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> put_view(ChamWeb.ItemJSON)
        |> render("error.json", error: "not found")
    end
  end

  def reprocess(conn, %{"id" => id} = params) do
    retry_failed = params["retry_failed"] == true || params["retry_failed"] == "true"
    invalidate = Map.get(params, "invalidate", [])

    case Items.get_item_by_slug_or_id(id) do
      {:ok, item} ->
        case Pipeline.reprocess(item.id, retry_failed: retry_failed, invalidate: invalidate) do
          {:ok, updated} ->
            conn
            |> put_status(:accepted)
            |> put_view(ChamWeb.ItemJSON)
            |> render("show.json", item: updated)

          {:error, _} ->
            conn
            |> put_status(:unprocessable_entity)
            |> put_view(ChamWeb.ItemJSON)
            |> render("error.json", error: "failed to reprocess item")
        end

      {:error, :ambiguous} ->
        conn
        |> put_status(:conflict)
        |> put_view(ChamWeb.ItemJSON)
        |> render("error.json", error: "ambiguous id prefix; multiple items match")

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
