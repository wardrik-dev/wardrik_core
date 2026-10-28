defmodule WardrikCore.Keys do
  @moduledoc """
  Gives the code you install the keys it calls services with, like a model provider's or a search
  API's, for whoever the agent works for.

  A keys module fetches a key by name, for the agent's `WardrikCore.Principal`. Give an agent one as
  `keys: {MyApp.Keys, opts}`, and a capability or middleware fetches what it needs:

      with {:ok, key} <- WardrikCore.Keys.fetch(context, "BRAVE_API_KEY") do
        Brave.search(key, query)
      end

  Every model call fetches its provider's key too, by the name ReqLLM gives it, as
  `ANTHROPIC_API_KEY`, and passes it to that call alone. Where there's no keys module, or it holds no
  such key, ReqLLM finds one itself, in its config or the environment.

  Keys are for the code you install. A tool that acts for someone takes their credentials instead,
  from `WardrikCore.Credentials`, so what an agent's owner configures never reads a key of yours.

  A key is a value, never kept in the context, so it's never saved or emitted.
  """

  alias WardrikCore.Context

  @callback fetch(name :: String.t(), WardrikCore.Principal.t() | nil, opts :: term()) ::
              {:ok, String.t()} | :error

  @doc "Fetches the key `name` for whoever the agent works for, or `:error` where none is held."
  @spec fetch(Context.t(), String.t()) :: {:ok, String.t()} | :error
  def fetch(%Context{keys: nil}, _name), do: :error

  def fetch(%Context{keys: {module, opts}, principal: principal}, name),
    do: module.fetch(name, principal, opts)

  def fetch(%Context{keys: module, principal: principal}, name),
    do: module.fetch(name, principal, [])

  @doc "Returns the options a call to `model` takes its provider's key in, `[api_key: key]`, or none."
  @spec model_options(Context.t(), LLMDB.Model.t() | String.t()) :: keyword()
  def model_options(%Context{keys: nil}, _model), do: []

  def model_options(context, model) do
    with name when is_binary(name) <- key_name(model),
         {:ok, key} <- fetch(context, name) do
      [api_key: key]
    else
      _none -> []
    end
  end

  @doc "Returns the name of the key `model`'s provider takes, as `ZAI_API_KEY`, or `nil`."
  @spec key_name(LLMDB.Model.t() | String.t()) :: String.t() | nil
  def key_name(%{provider: provider}) when is_atom(provider), do: env_key(provider)

  def key_name(spec) when is_binary(spec) do
    case String.split(spec, ":", parts: 2) do
      [provider, _model] -> provider |> existing_atom() |> env_key()
      _unnamed -> nil
    end
  end

  def key_name(_model), do: nil

  defp existing_atom(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> nil
  end

  defp env_key(nil), do: nil

  defp env_key(provider) do
    with {:ok, module} <- ReqLLM.provider(provider),
         true <- function_exported?(module, :default_env_key, 0) do
      module.default_env_key()
    else
      _unknown -> nil
    end
  end
end
