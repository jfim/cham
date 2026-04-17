defmodule Cham.Config.Events do
  defmodule ConfigChanged do
    @enforce_keys [:namespace, :values]
    defstruct [:namespace, :values]
  end
end
