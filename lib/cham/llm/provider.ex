defmodule Cham.LLM.Provider do
  @moduledoc """
  Behaviour for LLM chat providers plus a thin `generate/3` helper that wraps a
  single user prompt into a chat call.
  """
  @callback chat(messages :: [map()], opts :: keyword()) ::
              {:ok, String.t()} | {:error, term()}

  def generate(provider, prompt, opts) do
    provider.chat([%{"role" => "user", "content" => prompt}], opts)
  end
end
