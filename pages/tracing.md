# Tracing

A turn is a trace. Each model call and tool call is a span beneath it, as in OpenTelemetry.

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

## Attributes and measurements

Middleware adds attributes and measurements to the step it's in. This one tags each model call:

```elixir
defmodule MyApp.Trace do
  @behaviour WardrikCore.Middleware

  alias WardrikCore.Context

  @impl true
  def call(%Context{step: :generate} = context, next, _opts) do
    context
    |> Context.attribute("app.tenant", "acme")
    |> Context.measure(:model_calls, 1)
    |> next.()
  end

  def call(context, next, _opts), do: next.(context)
end
```

Each step reports its attributes and measurements when it ends, on
`[:wardrik_core, :step, :stop]`. Measurements add up over the turn. Print them:

```elixir
:telemetry.attach(
  "print-steps",
  [:wardrik_core, :step, :stop],
  fn _name, measurements, metadata, _config ->
    IO.inspect({metadata.step, metadata.attributes, Map.delete(measurements, :duration)})
  end,
  nil
)

{:ok, agent} =
  WardrikCore.start_agent(
    agent_id: "support",
    model: "anthropic:claude-haiku-4-5",
    middleware: [MyApp.Trace]
  )

:ok = WardrikCore.ask(agent, "What's on fire?")
# {:generate, %{"app.tenant" => "acme"}, %{model_calls: 1, input_tokens: 12, output_tokens: 48, usd: 0.000252}}
# {:turn, %{}, %{model_calls: 1, input_tokens: 12, output_tokens: 48, usd: 0.000252}}
```

Core measures every model call's `input_tokens` and `output_tokens`. It also measures `usd` if the
model has a price in dollars.

## Spans

A turn keeps its trace through a park or a restart. A tool call that runs again after a restart
keeps its span. `WardrikCore.Span.traceparent/1` returns a span as a W3C `traceparent` header,
such as for a call to another service:

```elixir
:telemetry.detach("print-steps")

:telemetry.attach(
  "print-traceparent",
  [:wardrik_core, :step, :stop],
  fn _name, _measurements, %{span: span}, _config ->
    IO.puts(WardrikCore.Span.traceparent(span))
  end,
  nil
)

:ok = WardrikCore.ask(agent, "And now?")
# 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
# ...
```
