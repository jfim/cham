defmodule Cham.Stage do
  @type artifact_result :: %{
          labels: map(),
          filenames: [String.t()]
        }

  @type perform_result :: %{
          artifacts: [artifact_result()],
          item_metadata: map(),
          provenance: map()
        }

  @type input_artifact :: %{
          labels: map(),
          filenames: [String.t()],
          input_path: String.t()
        }

  @callback name() :: String.t()
  @callback description() :: String.t()

  @callback perform(
              input_artifacts :: [input_artifact()],
              working_dir :: String.t(),
              desired_artifacts :: [map()],
              item_id :: String.t()
            ) :: {:ok, perform_result()} | {:error, term()} | {:snooze, pos_integer(), String.t()}

  @callback input_matchers() :: [map()]
  @callback output_labels() :: [map()]

  @callback can_process?(current_artifacts :: [map()]) ::
              {:ready, required :: [map()], optional :: [map()]}
              | :not_applicable
              | :undecided

  @callback queue() :: atom()
  @callback max_attempts() :: pos_integer()

  @optional_callbacks [input_matchers: 0, output_labels: 0, can_process?: 1]
end
