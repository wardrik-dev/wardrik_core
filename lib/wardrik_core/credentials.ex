defmodule WardrikCore.Credentials do
  @moduledoc """
  Gives tools the credentials of whoever the turn acts for.

  Use it when a tool acts as a person, with their own token. For your own API keys, see
  `WardrikCore.Keys`.

      defmodule MyApp.Vault do
        @behaviour WardrikCore.Credentials

        @impl true
        def resolve(_name, nil, _opts), do: {:error, "There's no one to act for."}

        def resolve(name, %WardrikCore.Principal{id: id}, _opts) do
          case MyApp.Tokens.get(id, name) do
            %{access_token: token} -> {:ok, token}
            nil -> {:authorize, "https://app.example.com/connect/\#{name}"}
          end
        end
      end

  Give it to an agent as `credentials: {MyApp.Vault, opts}`. A tool then fetches what it needs:

      run: fn %{title: title}, context ->
        with {:ok, token} <- WardrikCore.Credentials.fetch(context, "github") do
          GitHub.create_issue(token, title)
        end
      end

  If the person hasn't granted the credential yet, the call parks on a
  `WardrikCore.Authorization`. Once they've signed in, resume the turn and the call runs again.

  If a service refuses a credential, such as with a 401, call `refused/2` and fetch again. The
  module should return a fresh credential, or a new sign-in.

  Credentials are never kept in the context, so they're never saved or emitted. Keep them out of
  private data and attributes too.

  See the [Credentials](credentials.html) guide.
  """
  alias WardrikCore.Authorization
  alias WardrikCore.Context

  @doc """
  Returns the credential `name` for `principal`.

    * `{:ok, secret}` - the credential.
    * `{:authorize, url}` - the person must sign in at `url` first.
    * `{:error, reason}` - it can't be given.
  """
  @callback resolve(name :: String.t(), WardrikCore.Principal.t() | nil, opts :: term()) ::
              {:ok, secret :: term()} | {:authorize, url :: String.t()} | {:error, term()}

  @doc "Called when a service refused the credential `name`. Optional."
  @callback refused(name :: String.t(), WardrikCore.Principal.t() | nil, opts :: term()) :: :ok

  @optional_callbacks refused: 3

  @doc """
  Fetches the credential `name` for whoever the turn acts for.

  Returns `{:park, authorization}` if the person must sign in first, and `{:error, reason}` if the
  agent has no credentials module. See `WardrikCore.Context.acting_for/1`.
  """
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

  @doc "Tells the credentials module that a service refused the credential `name`, so it isn't given again."
  @spec refused(Context.t(), String.t()) :: :ok
  def refused(%Context{credentials: nil}, _name), do: :ok

  def refused(%Context{credentials: entry} = context, name) do
    {module, opts} = Context.entry(entry)
    told(module, name, Context.acting_for(context), opts)
  end

  defp told(module, name, principal, opts) do
    if Code.ensure_loaded?(module) and function_exported?(module, :refused, 3),
      do: module.refused(name, principal, opts),
      else: :ok
  end

  defp fetched({:authorize, url}, name, principal),
    do: {:park, %Authorization{url: url, credential: name, principal: principal}}

  defp fetched(resolved, _name, _principal), do: resolved
end
