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
message back up when it starts again.

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

Notice the orders arrive as the capability's options, `{MyApp.Orders, opts}`, so one module serves
many agents. Each tool call runs in its own process: one that crashes or times out is answered with
an error, and the turn carries on.

## Wrap every call

Middleware sees each turn, model call and tool call, as `context.step`. Here's one that asks a
person before any tool runs:

```elixir
defmodule MyApp.Approve do
  @behaviour WardrikCore.Middleware

  alias WardrikCore.Context

  @impl true
  def call(%Context{step: {:tool_call, call}, resume: {:approval, decisions}} = context, next, _opts) do
    case Map.get(decisions, call.id) do
      :approve -> next.(context)
      {:deny, reason} -> {:error, reason}
      nil -> {:park, :approval, context}
    end
  end

  def call(%Context{step: {:tool_call, _call}} = context, _next, _opts), do: {:park, :approval, context}
  def call(context, next, _opts), do: next.(context)
end
```

The turn parks until we resume it:

```elixir
{:tool_calls, calls} = WardrikCore.parked(agent)
WardrikCore.resume(agent, %{"call_1" => :approve})
```

Reach for middleware when every call needs the same treatment: policy, tracing, retries, a system
prompt. Like capabilities, it takes options as `{MyApp.Approve, opts}`.

## Control a running agent

| Function | Does |
| --- | --- |
| `ask/3` | Queues a message; a running turn ends at its next step and the next turn answers it |
| `interrupt/1` | Stops the running or parked turn |
| `resume/2` | Re-enters a parked turn |
| `status/1`, `history/1`, `parked/1` | What the agent is doing, has said, and waits on |
| `configure/2` | Replaces the model or settings, from the next turn |
| `stop/1` | Stops the agent until it is started again |
| `list/1`, `whereis/2` | Every saved agent's id, and the running agent for an id |

## Events

Agents emit `:telemetry` events for their lifecycle: messages queued, turns started and stopped,
checkpoints, and tool calls that died. `WardrikCore.Telemetry` lists them.

## License

Apache-2.0
