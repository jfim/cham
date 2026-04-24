defmodule ChamWeb.ConfigLive do
  use ChamWeb, :live_view

  alias Cham.Config.Manager, as: ConfigManager
  alias Cham.Plugin.Registry

  @impl true
  def mount(_params, _session, socket) do
    plugins = load_plugins()
    subscription_backends = load_subscription_backends()
    system_sections = load_system_sections()

    {:ok,
     socket
     |> assign(:page_title, "Configuration")
     |> assign(:plugins, plugins)
     |> assign(:subscription_backends, subscription_backends)
     |> assign(:system_sections, system_sections)
     |> assign(:active_section, nil)
     |> assign(:form_values, %{})
     |> assign(:overridden, %{})
     |> assign(:save_result, nil)}
  end

  @impl true
  def handle_event("select_section", %{"namespace" => namespace}, socket) do
    section = find_section(socket, namespace)

    if section do
      values = read_section_config(namespace)
      raw = read_section_raw(namespace)

      form_values =
        Enum.into(section.schema, %{}, fn field ->
          {Atom.to_string(field.key), format_value(Map.get(values, field.key, field.default))}
        end)

      overridden =
        Enum.into(section.schema, %{}, fn field ->
          {Atom.to_string(field.key), Map.has_key?(raw, Atom.to_string(field.key))}
        end)

      {:noreply,
       socket
       |> assign(:active_section, section)
       |> assign(:form_values, form_values)
       |> assign(:overridden, overridden)
       |> assign(:save_result, nil)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("reset_key", %{"key" => key}, socket) do
    section = socket.assigns.active_section

    if section do
      :ok = ConfigManager.reset_key(section.namespace, key)

      values = read_section_config(section.namespace)
      raw = read_section_raw(section.namespace)

      form_values =
        Enum.into(section.schema, %{}, fn field ->
          {Atom.to_string(field.key), format_value(Map.get(values, field.key, field.default))}
        end)

      overridden =
        Enum.into(section.schema, %{}, fn field ->
          {Atom.to_string(field.key), Map.has_key?(raw, Atom.to_string(field.key))}
        end)

      {:noreply,
       socket
       |> assign(:form_values, form_values)
       |> assign(:overridden, overridden)
       |> assign(:save_result, nil)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("save_config", params, socket) do
    section = socket.assigns.active_section

    if section do
      coerced =
        Enum.into(section.schema, %{}, fn field ->
          key_str = Atom.to_string(field.key)
          raw = Map.get(params, key_str, "")
          {key_str, coerce_value(raw, field.type)}
        end)

      case ConfigManager.write_all(section.namespace, coerced) do
        :ok ->
          raw = read_section_raw(section.namespace)

          overridden =
            Enum.into(section.schema, %{}, fn field ->
              {Atom.to_string(field.key), Map.has_key?(raw, Atom.to_string(field.key))}
            end)

          {:noreply,
           socket
           |> assign(:save_result, :ok)
           |> assign(:overridden, overridden)
           |> assign(:form_values, Map.new(params, fn {k, v} -> {k, v} end))}

        {:error, errors} ->
          {:noreply, assign(socket, :save_result, {:error, errors})}
      end
    else
      {:noreply, socket}
    end
  end

  defp load_plugins do
    Registry.list_plugins()
    |> Enum.map(fn entry ->
      %{
        namespace: "plugins.#{entry.plugin_id}",
        name: entry.name,
        description: entry.description,
        schema: entry.config_schema,
        kind: :plugin
      }
    end)
  end

  defp load_system_sections do
    ConfigManager.list_schemas()
    |> Enum.reject(fn {ns, _schema} ->
      String.starts_with?(ns, "plugins.") or String.starts_with?(ns, "subscriptions.")
    end)
    |> Enum.map(fn {namespace, schema} ->
      %{
        namespace: namespace,
        name: section_name(namespace),
        description: section_description(namespace),
        schema: schema,
        kind: :system
      }
    end)
  end

  defp load_subscription_backends do
    case Process.whereis(Cham.Subscriptions.BackendRegistry) do
      nil ->
        []

      _pid ->
        Cham.Subscriptions.BackendRegistry.list()
        |> Enum.map(fn mod ->
          schema =
            if function_exported?(mod, :config_schema, 0), do: mod.config_schema(), else: []

          %{
            namespace: "subscriptions.#{mod.id()}",
            name: mod.name(),
            description: "",
            schema: schema,
            kind: :subscription_backend
          }
        end)
        |> Enum.sort_by(& &1.name)
    end
  end

  defp section_name("desired_artifacts"), do: "Desired Artifacts"
  defp section_name("enabled_plugins"), do: "Enabled Plugins"
  defp section_name("display"), do: "Display"
  defp section_name("pipeline"), do: "Pipelines"
  defp section_name(ns), do: ns

  defp section_description("desired_artifacts"),
    do: "Configure which artifacts are produced per content type"

  defp section_description("enabled_plugins"),
    do: "Enable or disable individual plugins"

  defp section_description(_), do: ""

  defp find_section(socket, namespace) do
    Enum.find(
      socket.assigns.system_sections ++
        socket.assigns.subscription_backends ++ socket.assigns.plugins,
      fn s -> s.namespace == namespace end
    )
  end

  defp read_section_config(namespace) do
    case ConfigManager.read_all(namespace) do
      {:ok, values} -> values
      {:error, _} -> %{}
    end
  end

  defp read_section_raw(namespace) do
    case ConfigManager.read_raw(namespace) do
      {:ok, values} -> values
      {:error, _} -> %{}
    end
  end

  defp format_value(nil), do: ""
  defp format_value(true), do: "true"
  defp format_value(false), do: "false"
  defp format_value(value) when is_binary(value), do: value
  defp format_value(value), do: to_string(value)

  defp coerce_value(value, :integer) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> value
    end
  end

  defp coerce_value(value, :float) do
    case Float.parse(value) do
      {float, _} -> float
      :error -> value
    end
  end

  defp coerce_value("true", :boolean), do: true
  defp coerce_value("false", :boolean), do: false
  defp coerce_value(value, _type), do: value

  defp input_type(:integer), do: "number"
  defp input_type(:float), do: "number"
  defp input_type(:url), do: "url"
  defp input_type(_), do: "text"

  defp is_long_text?(field) do
    field.type == :string and is_binary(field.default) and String.length(field.default) > 80
  end

  defp has_config?(plugin), do: plugin.schema != []

  # Known acronyms that should be rendered fully uppercase in humanized labels.
  @acronyms ~w(llm api url id http json toml uri uuid ip tcp udp sql html css db)

  @doc """
  Humanizes a config key like `oban.queues` or `llm.api_key` into a display
  label like `Oban Queues` or `LLM API Key`. Words that match known acronyms
  are uppercased.
  """
  def humanize_key(key) when is_atom(key), do: humanize_key(Atom.to_string(key))

  def humanize_key(key) when is_binary(key) do
    key
    |> String.split(~r/[._]/, trim: true)
    |> Enum.map(&humanize_word/1)
    |> Enum.join(" ")
  end

  defp humanize_word(word) do
    downcased = String.downcase(word)

    if downcased in @acronyms do
      String.upcase(downcased)
    else
      String.capitalize(downcased)
    end
  end
end
