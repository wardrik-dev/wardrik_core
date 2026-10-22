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

Let's run agents under our app, with their state kept in EKV:

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
(`:infinity` unless set), and `max_rounds`, the model calls a turn may make (25 unless set).

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
WardrikCore.resume(agent, %{"call_1" => :approve}, %{by: "maria"})
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

## Events

Agents emit `:telemetry` events: messages queued, turns started and stopped, every step's start and
stop with its span, checkpoints, and tool calls that died. `WardrikCore.Telemetry` lists them.

## License

Apache-2.0
