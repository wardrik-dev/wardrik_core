# Tools

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
