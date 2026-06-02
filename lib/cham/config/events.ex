defmodule Cham.Config.Events do
  @moduledoc "Event structs broadcast by `Cham.Config.Manager` on config changes."
  defmodule ConfigChanged do
    @moduledoc "Emitted when a config namespace's values are updated."
    @enforce_keys [:namespace, :values]
    defstruct [:namespace, :values]
  end
end
