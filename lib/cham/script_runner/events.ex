defmodule Cham.ScriptRunner.Events do
  @moduledoc """
  Event structs published by `Cham.ScriptRunner` over the event bus during
  script execution (output, exit, timeout).
  """
  defmodule ScriptOutput do
    @moduledoc "A chunk of output emitted by a running script."
    @enforce_keys [:ref, :data]
    defstruct [:ref, :data]
  end

  defmodule ScriptExited do
    @moduledoc "Emitted when a script process exits with an exit code."
    @enforce_keys [:ref, :exit_code]
    defstruct [:ref, :exit_code]
  end

  defmodule ScriptTimeout do
    @moduledoc "Emitted when a running script exceeds its timeout."
    @enforce_keys [:ref]
    defstruct [:ref]
  end
end
