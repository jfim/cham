defmodule Cham.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    migrate()

    children =
      [
        ChamWeb.Telemetry,
        Cham.Repo,
        {Oban, Application.fetch_env!(:cham, Oban)},
        {DNSCluster, query: Application.get_env(:cham, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Cham.PubSub},
        {Cham.Config.Manager,
         toml_path: Application.get_env(:cham, :config_toml_path, "config/cham.toml"),
         event_bus: Cham.PubSub},
        {Cham.Plugin.Registry, name: Cham.Plugin.Registry, plugin_order: []},
        {Cham.Subscriptions.BackendRegistry, []}
      ] ++
        orchestrator_children() ++
        tracker_children() ++
        [
          # Start to serve requests, typically the last entry
          ChamWeb.Endpoint
        ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Cham.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        register_core_plugins()
        register_pipeline_config()
        register_desired_artifacts_config()
        register_enabled_plugins_config()
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

  defp register_core_plugins do
    core_plugins = [
      Cham.Plugins.GenericDownloadUrl,
      Cham.Plugins.ContentTypeRouter,
      Cham.Plugins.ExtractArticle,
      Cham.Plugins.ExtractFeedItems,
      Cham.Plugins.ExtractPdf,
      Cham.Plugins.ExtractAudio,
      Cham.Plugins.TranscribeWhisper,
      Cham.Plugins.TranscribeFireworks,
      Cham.Plugins.SummarizeOllama,
      Cham.Plugins.AutoTag,
      Cham.Plugins.CleanTitle,
      Cham.Plugins.ExtractThumbnail
    ]

    for mod <- core_plugins do
      case Cham.Plugin.Registry.register_plugin(mod, %{}) do
        :ok ->
          register_plugin_config(mod)

        {:error, reason} ->
          Logger.warning("Failed to register plugin #{mod.plugin_id()}: #{inspect(reason)}")
      end
    end
  end

  defp register_pipeline_config do
    schema = [
      %{
        key: :fallback_bootstrap_stage,
        type: :string,
        default: "generic_download_url",
        description:
          "Plugin ID of the bootstrap stage to use when no specialized downloader matches the URL",
        required: false,
        options: nil
      }
    ]

    Cham.Config.Manager.register("pipeline", schema)
  end

  defp register_desired_artifacts_config do
    defaults = Cham.Pipeline.DesiredStages.defaults()

    schema =
      Enum.map(defaults, fn {content_type, labels} ->
        types = Enum.map_join(labels, ", ", fn m -> m["type"] end)

        %{
          key: String.to_atom(content_type),
          type: :string,
          default: types,
          description:
            "Comma-separated desired artifact types for #{content_type} items (e.g. content, summary, tags, transcript, clean_title)",
          required: false,
          options: nil
        }
      end)

    Cham.Config.Manager.register("desired_artifacts", schema)
  end

  defp register_enabled_plugins_config do
    plugins = Cham.Plugin.Registry.list_plugins()

    schema =
      Enum.map(plugins, fn entry ->
        %{
          key: String.to_atom(entry.plugin_id),
          type: :boolean,
          default: true,
          description: entry.description,
          required: false,
          options: nil
        }
      end)

    Cham.Config.Manager.register("enabled_plugins", schema)
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
          Logger.warning(
            "Failed to register config for backend #{mod.id()}: #{inspect(reason)}"
          )
      end
    end
  end

  defp register_plugin_config(mod) do
    schema = mod.config_schema()

    if schema != [] do
      namespace = "plugins.#{mod.plugin_id()}"

      case Cham.Config.Manager.register(namespace, schema) do
        :ok ->
          :ok

        {:error, :already_registered} ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to register config for #{mod.plugin_id()}: #{inspect(reason)}")
      end
    end
  end

  defp orchestrator_children do
    if Application.get_env(:cham, :start_orchestrator, true) do
      [Cham.Pipeline.Orchestrator]
    else
      []
    end
  end

  defp tracker_children do
    if Application.get_env(:cham, :start_tracker, true) do
      [Cham.JobTracking.Tracker]
    else
      []
    end
  end

  @impl true
  def config_change(changed, _new, removed) do
    ChamWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
