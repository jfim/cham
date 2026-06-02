defmodule Cham.Application do
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    migrate()

    children = [
      ChamWeb.Telemetry,
      Cham.Repo,
      {DNSCluster, query: Application.get_env(:cham, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Cham.PubSub},
      {Cham.Config.Manager,
       toml_path: Application.get_env(:cham, :config_toml_path, "config/cham.toml"),
       event_bus: Cham.PubSub},
      Cham.Subscriptions.Supervisor,
      {Cham.MCP.Server, transport: :streamable_http},
      ChamWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Cham.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        register_display_config()
        Cham.Subscriptions.BackendRegistry.register(Cham.Subscriptions.Backends.RSS)
        register_subscription_backend_config(Cham.Subscriptions.Backends.RSS)
        {:ok, pid}

      error ->
        error
    end
  end

  defp migrate do
    unless Application.get_env(:cham, :skip_migrations, false) do
      ensure_database_created()

      {:ok, _, _} =
        Ecto.Migrator.with_repo(Cham.Repo, fn repo ->
          Ecto.Migrator.run(repo, :up, all: true)
        end)
    end
  end

  defp ensure_database_created do
    case Cham.Repo.__adapter__().storage_up(Cham.Repo.config()) do
      :ok -> Logger.info("Database created")
      {:error, :already_up} -> :ok
      {:error, reason} -> Logger.warning("Could not create database: #{inspect(reason)}")
    end
  end

  defp register_display_config do
    schema = [
      %{
        key: :thumbnail_provider_order,
        type: :string,
        default: "ffmpeg",
        description:
          "Comma-separated list of thumbnail providers in preference order. " <>
            "The first provider with an available artifact wins.",
        required: false,
        options: nil
      },
      %{
        key: :title_provider_order,
        type: :string,
        default: "clean_title",
        description:
          "Comma-separated list of title-override providers in preference order. " <>
            "Falls back to item.title when none match.",
        required: false,
        options: nil
      },
      %{
        key: :content_order,
        type: :string,
        default: "cleaned_content,content",
        description:
          "Comma-separated list of content artifact types to display for articles, in " <>
            "preference order. For each type, the derived artifact is preferred over the " <>
            "original. Known types: cleaned_content, content.",
        required: false,
        options: nil
      }
    ]

    case Cham.Config.Manager.register("display", schema) do
      :ok -> :ok
      {:error, :already_registered} -> :ok
      {:error, reason} -> Logger.warning("Failed to register display config: #{inspect(reason)}")
    end
  end

  defp register_subscription_backend_config(mod) do
    schema = if function_exported?(mod, :config_schema, 0), do: mod.config_schema(), else: []

    if schema != [] do
      namespace = "subscriptions.#{mod.id()}"

      case Cham.Config.Manager.register(namespace, schema) do
        :ok ->
          :ok

        {:error, :already_registered} ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to register config for backend #{mod.id()}: #{inspect(reason)}")
      end
    end
  end

  @impl true
  def config_change(changed, _new, removed) do
    ChamWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
