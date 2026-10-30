# Tools

## Setup

Paste this into a fresh IEx session. The model calls need an Anthropic key:

```elixir
Mix.install([{:wardrik_core, "~> 0.1.0-rc.1"}])
System.put_env("ANTHROPIC_API_KEY", "sk-ant-...")

children = [
  {WardrikCore.Backends.MemoryStore, name: :agents},
  {WardrikCore, backend: {WardrikCore.Backends.MemoryStore, name: :agents}}
]

{:ok, _} = Supervisor.start_link(children, strategy: :rest_for_one)
```

Replace `"sk-ant-..."` with your key.

## Capabilities

A capability is a module that gives an agent its tools:

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

WardrikCore.history(agent)
#=> [#Message<:user text>, #Message<:assistant ...>, #Message<:tool text>,
#=>  #Message<:assistant text>]
```

The orders are the capability's options, from `{MyApp.Orders, opts}`, so one module can serve many
agents.

Each tool call runs in its own process. A call that crashes or times out is answered with an error,
and the turn carries on.

## Annotations

Annotations describe a tool, such as `read_only: true` or `idempotent: true`. Any package can read
them. A policy can decide by them, and core repeats an idempotent call lost in a crash.

```elixir
tool =
  WardrikCore.Tool.new!(
    name: "order_status",
    description: "Say where an order is.",
    schema: [order_id: [type: :string, required: true]],
    run: fn %{order_id: _id}, _context -> {:ok, "shipped"} end,
    annotations: [read_only: true, idempotent: true]
  )

WardrikCore.Tool.annotation(tool, :idempotent)
#=> true
```

See `WardrikCore.Tool` for every annotation and return value.

## Reporting cost

A tool that calls a paid API reports the cost by returning its context, measured:

```elixir
WardrikCore.Tool.new!(
  name: "enrich",
  description: "Find a person's company from their email.",
  schema: [email: [type: :string, required: true]],
  run: fn %{email: email}, context ->
    found = %{email: email, company: "Acme"}
    {:ok, found, WardrikCore.Context.measure(context, :usd, 0.01)}
  end
)
```

The cost is added to the tool call's measurements, and to the turn's. See [Tracing](tracing.md).
