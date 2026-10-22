defmodule WardrikCore.Credentials do
  @moduledoc """
  Gives a tool the credentials it needs, for whoever its turn acts for.

  A credentials module resolves a credential by name, for a `WardrikCore.Principal`. Give an agent
  one as `credentials: {MyApp.Vault, opts}`, and a tool fetches what it needs:

      run: fn %{title: title}, context ->
        with {:ok, token} <- WardrikCore.Credentials.fetch(context, "github") do
          GitHub.create_issue(token, title)
        end
      end

  A credential the person hasn't granted yet parks the call on a `WardrikCore.Authorization`. Once
  they've signed in, resume the turn, and the call runs again.

  A credential is a value, never kept in the context, so it's never saved or emitted. Keep it out of
  private data and attributes too.

  Reach for this when a tool acts as a person, with their own token.
  """
  alias WardrikCore.Authorization
  alias WardrikCore.Context

  @callback resolve(name :: String.t(), WardrikCore.Principal.t() | nil, opts :: term()) ::
              {:ok, secret :: term()} | {:authorize, url :: String.t()} | {:error, term()}

  @doc "Fetches the credential `name` for whoever the turn acts for. See `Context.acting_for/1`."
  @spec fetch(Context.t(), String.t()) ::
          {:ok, term()} | {:park, Authorization.t()} | {:error, term()}
  def fetch(%Context{credentials: nil}, name), do: {:error, "No credentials to give #{name}."}

  def fetch(%Context{credentials: entry} = context, name) do
    {module, opts} = Context.entry(entry)
    principal = Context.acting_for(context)

    name
    |> module.resolve(principal, opts)
    |> fetched(name, principal)
  end

  defp fetched({:authorize, url}, name, principal),
    do: {:park, %Authorization{url: url, credential: name, principal: principal}}

  defp fetched(resolved, _name, _principal), do: resolved
end
