defmodule Cham.ScriptRunner.Events do
  defmodule ScriptOutput do
    @enforce_keys [:ref, :data]
    defstruct [:ref, :data]
  end

  defmodule ScriptExited do
    @enforce_keys [:ref, :exit_code]
    defstruct [:ref, :exit_code]
  end

  defmodule ScriptTimeout do
    @enforce_keys [:ref]
    defstruct [:ref]
  end
end
