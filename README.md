# WardrikCore

Durable agents for Elixir: a model and its tools in a loop, that pick up where they left off after a crash.

## Install

```elixir
def deps do
  [
    {:wardrik_core, "~> 0.1"},
    {:ekv, "~> 0.4"}
  ]
end
```

## Start an agent

Let's run agents in your app, with their state kept in EKV:

```elixir
children = [
  {EKV, name: :agents_store, data_dir: "/var/lib/my_app/agents", cluster_size: 1},
  {WardrikCore, backend: {DurableServer.Backends.EKVStore, name: :agents_store}}
]

Supervisor.start_link(children, strategy: :rest_for_one)

{:ok, agent} = WardrikCore.start_agent(agent_id: "triage", model: "anthropic:claude-haiku-4-5")
:ok = WardrikCore.ask(agent, "What's on fire?")
```

Notice `ask/3` returns once the message is stored. If the node dies mid-turn, the agent picks the
message back up when it starts again. A turn lost while its tools ran carries on from its last
checkpoint, without asking the model again.

A tool call lost that way may already have run. It's repeated only if its tool is annotated
`idempotent: true`, meaning a repeat leaves things as one run did. Any other call parks as
`:in_doubt`. Answer it with `resume/3`, giving the
call's id `:approve` to run it again, or `{:deny, reason}` to tell the model why it didn't.

In tests, start `{WardrikCore.Backends.MemoryStore, name: :agents_store}` in EKV's place and name
it as the backend. It keeps agents in memory, so they're gone when the node stops.

`start_agent/2` also takes `capabilities`, `middleware`, `metadata`, a turn's `timeout`
(`:infinity` unless set), `max_rounds`, the model calls a turn may make (25 unless set), and the
agent's `principal`.

## Act on someone's behalf

A principal is someone or something that can act, as in IAM. An agent has one of its own, like a
service account. A message can come from another, and the turn that answers acts on their behalf:

```elixir
alias WardrikCore.Principal

{:ok, agent} =
  WardrikCore.start_agent(
    agent_id: "support",
    model: "anthropic:claude-haiku-4-5",
    principal: %Principal{id: "agent:support"}
  )

maria = %Principal{id: "user:maria", attributes: %{org: "acme"}}
:ok = WardrikCore.ask(agent, "Open an issue for the login bug.", %{principal: maria})
```

Middleware and tools find who the turn acts for with `Context.acting_for/1`: whoever asked, else
the agent itself. A turn answers the messages in a row from one principal, never two, so one shared
agent never mixes two people's authority. Every step's span says who it was for, as
`"enduser.id"`.

Core keeps principals and passes them on, but never reads their `attributes`. They're for the
packages that decide by them, like a vault that keys secrets by `id`.

## Use their credentials

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

`[:wardrik_core, :turn, :stop]` carries a parked turn's `reason`, so you can watch who's waiting
on what, like on a dashboard, or with an alert for an agent left waiting. Its handlers run in the
agent's own process, so use them to watch, not to resume agents.

## Give it tools

A capability is a module that hands an agent its tools:

```elixir
defmodule MyApp.Orders do
  @behaviour WardrikCore.Capability

  @impl true
  def tools(_context, orders) do
    [
      WardrikCore.Tool.new!(
        name: "order_status",
        description: "Say where an order is.",
        schema: [order_id: [type: :string, required: true]],
        run: fn %{order_id: id}, _context -> {:ok, Map.get(orders, id, "unknown")} end
      )
    ]
  end
end

{:ok, agent} =
  WardrikCore.start_agent(
    agent_id: "support",
    model: "anthropic:claude-haiku-4-5",
    capabilities: [{MyApp.Orders, %{"1001" => "shipped"}}]
  )

:ok = WardrikCore.ask(agent, "Where is order 1001?")
```

The orders arrive as the capability's options, `{MyApp.Orders, opts}`, so one module serves
many agents. Each tool call runs in its own process: one that crashes or times out is answered with
an error, and the turn carries on.

A tool says what it is with annotations, like `read_only: true` or `idempotent: true`. Any package
can read them. A policy decides by them, and core repeats an idempotent call lost in a crash. A tool
that calls a paid API reports what it cost by answering with its context, measured:

```elixir
run: fn %{email: email}, context ->
  found = Enrich.lookup(email)
  {:ok, found, WardrikCore.Context.measure(context, :usd, 0.01)}
end
```

`WardrikCore.Tool` lists the annotations, and what a tool can answer.

## Wrap every call

Middleware sees each turn, model call and tool call, as `context.step`. It calls `next` to carry
on, or answers the step itself. Here's one that refuses the shell:

```elixir
defmodule MyApp.NoShell do
  @behaviour WardrikCore.Middleware

  @impl true
  def call(%{step: {:tool_call, %{name: "shell"}}} = context, _next, _opts),
    do: {:ok, %{context | response: {:error, "No shell."}}}

  def call(context, next, _opts), do: next.(context)
end
```

A refusal is the call's answer. The model sees it as the call's error, and carries on.

Middleware can also park a call until a person answers. This one asks before any tool runs:

```elixir
defmodule MyApp.Approve do
  @behaviour WardrikCore.Middleware

  @impl true
  def call(%{step: {:tool_call, call}} = context, next, _opts) do
    case answer(context, call) do
      :approve -> next.(context)
      {:deny, reason} -> {:ok, %{context | response: {:error, reason}}}
      nil -> {:park, :approval, context}
    end
  end

  def call(context, next, _opts), do: next.(context)

  defp answer(%{resume: %{input: answers}}, call), do: Map.get(answers, call.id)
  defp answer(_context, _call), do: nil
end
```

The turn waits until we resume it, with an answer for each call. Say who answered as the metadata,
and it's on the resumed turn's start event:

```elixir
{:tool_calls, calls} = WardrikCore.parked(agent)
WardrikCore.resume(agent, %{"call_1" => :approve}, %{by: maria})
```

Middleware can keep state with the agent, like a count or what it spent, with
`Context.put_private/3` under its own module's name. It's saved with the agent, so it survives
restarts. When middleware needs a model's judgement on a call, `WardrikCore.evaluate/4` asks an
evaluation model.

Reach for middleware when every call needs the same treatment: policy, tracing, retries, a system
prompt. Like capabilities, it takes options as `{MyApp.Approve, opts}`.

## Trace every step

A turn is a trace, and each model call and tool call is a span beneath it, as OpenTelemetry has
them. Middleware adds to the step it's in:

```elixir
def call(%Context{step: {:tool_call, call}} = context, next, _opts) do
  context
  |> Context.attribute("gen_ai.tool.name", call.name)
  |> Context.measure(:usd, 0.002)
  |> next.()
end
```

Each step reports its attributes and what it measured when it ends. Measurements add up over the
turn, and core measures every model call's `input_tokens` and `output_tokens`, and its `usd` when
the model has a price in dollars.

A turn keeps its trace through a park or a restart, and a tool call that runs again after a restart
keeps its span. `WardrikCore.Span.traceparent/1` gives a span as a W3C `traceparent` header.

## Control a running agent

| Function | Does |
| --- | --- |
| `ask/3` | Queues a message; a running turn ends at its next step and the next turn answers it |
| `interrupt/1` | Stops the running or parked turn |
| `resume/3` | Re-enters a parked turn, with who answered as its metadata |
| `status/1`, `history/1`, `parked/1` | What the agent is doing, has said, and waits on |
| `configure/2` | Replaces the model or settings, from the next turn |
| `stop/1` | Stops the agent until it is started again |
| `list/1`, `whereis/2` | Every saved agent's id, and the running agent for an id |

## Follow what an agent does

Every event an agent emits goes two places: to `:telemetry`, for metrics and traces, and to the
agent's events sink, for clients that follow it, like a CLI, a TUI or a web page. Give the agent a
`WardrikCore.Events` module:

```elixir
defmodule MyApp.Events do
  @behaviour WardrikCore.Events

  @impl true
  def handle_event(%WardrikCore.Event{} = event, _opts) do
    Phoenix.PubSub.broadcast(MyApp.PubSub, "agent:#{event.metadata.agent_id}", event)
  end
end

WardrikCore.start_agent(agent_id: "triage", model: "...", events: {MyApp.Events, []})
```

Each event names what happened, like `[:wardrik_core, :turn, :stop]`, with its measurements and
metadata. Text streams as `[:wardrik_core, :message, :delta]` while the model writes it.
`WardrikCore.Telemetry` lists core's events.

Packages emit theirs through the same sink with `WardrikCore.Event.emit/4`, so a client hears a
policy's decisions as well as the agent's turns.

The sink runs in the agent's process, as each event happens. Keep it quick: store or send the
event, and return. A durable log, numbering events for clients that reconnect, belongs in a
package.

## What core does, and doesn't

Core runs agents durably, and gives packages seams to extend them.

- **It runs agents:** turns, tools, checkpoints, parking and resuming, and carrying on after a
  crash.
- **It gives seams:** capabilities, middleware, tool annotations, principals, credentials, and
  events.
- **It leaves the rest to packages:** policy, MCP servers, storing secrets, OAuth, event logs,
  transports like HTTP, and clients.

Core changes for bugs, and for a seam no package can do without.

## License

Apache-2.0
