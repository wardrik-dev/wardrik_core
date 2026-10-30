# Tracing

A turn is a trace. Each model call and tool call is a span beneath it, as in OpenTelemetry.
Middleware adds attributes and measurements to the step it's in:

```elixir
def call(%Context{step: {:tool_call, call}} = context, next, _opts) do
  context
  |> Context.attribute("gen_ai.tool.name", call.name)
  |> Context.measure(:usd, 0.002)
  |> next.()
end
```

Each step reports its attributes and measurements when it ends, on
`[:wardrik_core, :step, :stop]`. Measurements add up over the turn.

Core measures every model call's `input_tokens` and `output_tokens`. It also measures `usd` if the
model has a price in dollars.

A turn keeps its trace through a park or a restart. A tool call that runs again after a restart
keeps its span. `WardrikCore.Span.traceparent/1` returns a span as a W3C `traceparent` header.
