defmodule ChamWeb.ItemJSON do
  def render("index.json", %{items: items}) do
    %{items: Enum.map(items, &item_json/1)}
  end

  def render("show.json", %{item: item}) do
    item_json(item)
  end

  def render("show_detail.json", %{
        item: item,
        artifacts: artifacts,
        stage_executions: stage_executions
      }) do
    item_json(item)
    |> Map.put(:artifacts, Enum.map(artifacts, &artifact_json/1))
    |> Map.put(:stage_executions, Enum.map(stage_executions, &stage_execution_json/1))
  end

  def render("error.json", %{error: message}) do
    %{error: message}
  end

  defp item_json(item) do
    %{
      id: item.id,
      url: item.url,
      status: item.status,
      title: item.title,
      slug: item.slug,
      content_type: item.content_type,
      tags: item.tags,
      error_message: item.error_message,
      metadata: item.metadata,
      inserted_at: item.inserted_at,
      updated_at: item.updated_at
    }
  end

  defp artifact_json(artifact) do
    %{
      stage: artifact.stage,
      labels: artifact.labels,
      filenames: artifact.filenames,
      status: artifact.status
    }
  end

  defp stage_execution_json(execution) do
    %{
      stage: execution.stage,
      status: execution.status,
      attempt: execution.attempt,
      duration_ms: execution.duration_ms,
      error: execution.error,
      started_at: execution.started_at,
      ended_at: execution.ended_at
    }
  end
end
