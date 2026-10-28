# Credentials

A tool that acts as a person needs their token. A `WardrikCore.Credentials` module finds it, by the
credential's name and the principal the turn acts for. Here's one that keeps tokens in your app's
own table, and sends a person to sign in when there's none yet:

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

It answers one of three ways:

- `{:ok, token}`, when it has the token.
- `{:authorize, url}`, when the person must sign in first. The URL is a page in your app, which
  starts the provider's OAuth flow for whoever is signed in.
- `{:error, reason}`, when it can't help.

`refused/3` is optional. A tool calls it through `WardrikCore.Credentials.refused/2` when a
service turns a token down, like with a 401. This vault forgets the token, so the next fetch sends
the person to sign in again.

Give it to the agent, and a tool fetches what it needs:

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

When the vault answers `{:authorize, url}`, the call parks on a `WardrikCore.Authorization`. It
carries the `url`, the `credential` and the `principal`, so you can show the right person where to
sign in:

```elixir
{:tool_calls, [{_call, {:park, %WardrikCore.Authorization{url: url}}}]} =
  WardrikCore.parked(agent)
```

Remember which agent asked, like in the OAuth `state` your app signs. Once the callback has stored
the token in `MyApp.Tokens`, resume that agent. Its id reaches it on any node in the cluster, and
the call runs again, this time with the token:

```elixir
agent_id
|> WardrikCore.whereis()
|> WardrikCore.resume(%{}, %{by: maria})
```

Another agent parked on the same sign-in still shows its own link. When the person opens it, your
app finds the token already stored, and resumes that agent straight away. They only sign in once.

A credential is a value. It's never kept in the context, so it's never saved or emitted.

## Keys

Credentials are what a tool's call needs as the person it acts for. Keys are what the code you
install needs as yours: a model provider's key, or a search API's. Give an agent a
`WardrikCore.Keys` module as `keys: {MyApp.Keys, opts}`, and it's asked for each key by name, for
the agent's principal, so an org can bring its own:

```elixir
defmodule MyApp.Keys do
  @behaviour WardrikCore.Keys

  @impl true
  def fetch(name, principal, _opts), do: MyApp.Vault.key(principal, name)
end
```

Every model call asks for its provider's key, by the name ReqLLM gives it, as `ANTHROPIC_API_KEY`,
and passes it to that call alone. A capability or middleware asks with
`WardrikCore.Keys.fetch(context, "BRAVE_API_KEY")`. Where none is held, ReqLLM finds a key itself,
in its config or the environment. Keep keys apart from credentials: a tool's credential is named by
what an agent's owner configures, and a key must never be.

`[:wardrik_core, :turn, :stop]` carries a parked turn's `reason`, so you can watch who's waiting
on what, like on a dashboard, or with an alert for an agent left waiting. Its handlers run in the
agent's own process, so use them to watch, not to resume agents.
