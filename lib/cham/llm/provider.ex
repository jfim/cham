defmodule Cham.LLM.Provider do
  @callback chat(messages :: [map()], opts :: keyword()) ::
              {:ok, String.t()} | {:error, term()}

  def generate(provider, prompt, opts) do
    provider.chat([%{"role" => "user", "content" => prompt}], opts)
  end
end
