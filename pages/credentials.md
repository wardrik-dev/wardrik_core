# Credentials

A tool that acts as a person needs their token. A `WardrikCore.Credentials` module finds it, by
the credential's name and the principal the turn acts for. This one keeps tokens in your app's own
table, and sends the person to sign in when there's none yet:

```elixir
defmodule MyApp.Vault do
  @behaviour WardrikCore.Credentials

  @impl true
  def resolve(_name, nil, _opts), do: {:error, "There's no one to act for."}

  def resolve(name, %WardrikCore.Principal{id: id}, opts) do
    case MyApp.Tokens.get(id, name) do
      %{access_token: token} -> {:ok, token}
      nil -> {:authorize, "#{opts[:base_url]}/connect/#{name}"}
    end
  end

  @impl true
  def refused(name, %WardrikCore.Principal{id: id}, _opts), do: MyApp.Tokens.delete(id, name)
end
```

`resolve/3` returns one of:

- `{:ok, token}` - the token.
- `{:authorize, url}` - the person must sign in first. The URL is a page in your app that starts
  the provider's OAuth flow for whoever is signed in.
- `{:error, reason}` - it can't help.

`refused/3` is optional. A tool calls it through `WardrikCore.Credentials.refused/2` when a service
rejects a token, such as with a 401. This vault forgets the token, so the next fetch sends the
person to sign in again.

## Using credentials

Give the module to the agent. A tool fetches what it needs:

```elixir
WardrikCore.start_agent(
  agent_id: "support",
  model: "anthropic:claude-haiku-4-5",
  credentials: {MyApp.Vault, base_url: "https://app.example.com"}
)

run: fn %{title: title}, context ->
  with {:ok, token} <- WardrikCore.Credentials.fetch(context, "github") do
    GitHub.create_issue(token, title)
  end
end
```

Credentials are never kept in the context, so they're never saved or emitted.

## Signing in

When `resolve/3` returns `{:authorize, url}`, the call parks on a `WardrikCore.Authorization`. It
holds the `url`, the `credential` and the `principal`, so you can show the right person where to
sign in:

```elixir
{:tool_calls, [{_call, {:park, %WardrikCore.Authorization{url: url}}}]} =
  WardrikCore.parked(agent)
```

1. Remember which agent asked, such as in the OAuth `state` your app signs.
2. In the callback, store the token in `MyApp.Tokens`.
3. Resume that agent. Its id finds it on any node in the cluster. The call runs again, this time
   with the token:

```elixir
agent_id
|> WardrikCore.whereis()
|> WardrikCore.resume(%{}, %{by: maria})
```

Another agent parked on the same sign-in still shows its own link. When the person opens it, your
app finds the token already stored and resumes that agent straight away. They only sign in once.

To watch who's waiting on what, such as for a dashboard or an alert, handle
`[:wardrik_core, :turn, :stop]`. It carries a parked turn's `reason`. Handlers run in the agent's
own process, so use them to watch, not to resume agents.

## Keys

Credentials are what a tool needs to act as a person. Keys are what your code needs as itself: a
model provider's key, or a search API's. Give the agent a `WardrikCore.Keys` module:

```elixir
defmodule MyApp.Keys do
  @behaviour WardrikCore.Keys

  @impl true
  def fetch(name, principal, _opts), do: MyApp.Vault.key(principal, name)
end

WardrikCore.start_agent(
  agent_id: "support",
  model: "anthropic:claude-haiku-4-5",
  keys: {MyApp.Keys, []}
)
```

Keys are fetched by name, for the agent's principal, so an org can bring its own.

- Every model call fetches its provider's key by the name ReqLLM gives it, such as
  `ANTHROPIC_API_KEY`, and passes it to that call only.
- A capability or middleware fetches with `WardrikCore.Keys.fetch(context, "BRAVE_API_KEY")`.
- If no key is held, ReqLLM finds one in its config or the environment.

Keep keys apart from credentials. A credential's name comes from what an agent's owner configures.
A key's name never should.
