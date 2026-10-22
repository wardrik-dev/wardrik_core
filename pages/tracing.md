# Tracing

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
