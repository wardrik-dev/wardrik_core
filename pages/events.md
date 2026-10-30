# Events

Every event an agent emits goes two places:

* `:telemetry`, for metrics and traces.
* The agent's events sink, for clients that follow it, such as a CLI, a TUI or a web page.

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

## A sink

Give the agent a `WardrikCore.Events` module. This one prints each event's name:

```elixir
defmodule MyApp.Events do
  @behaviour WardrikCore.Events

  @impl true
  def handle_event(%WardrikCore.Event{name: name}, _opts), do: IO.inspect(name)
end

{:ok, agent} =
  WardrikCore.start_agent(
    agent_id: "support",
    model: "anthropic:claude-haiku-4-5",
    events: {MyApp.Events, []}
  )
# [:wardrik_core, :agent, :start]

:ok = WardrikCore.ask(agent, "What's on fire?")
# [:wardrik_core, :message, :queued]
# [:wardrik_core, :turn, :start]
# [:wardrik_core, :step, :start]
# [:wardrik_core, :step, :start]
# [:wardrik_core, :message, :delta]
# ...
# [:wardrik_core, :step, :stop]
# [:wardrik_core, :step, :stop]
# [:wardrik_core, :turn, :stop]
```

In an app, send the event on to clients instead, such as with `Phoenix.PubSub.broadcast/3` on a
topic named for `event.metadata.agent_id`.

Each event has a name, such as `[:wardrik_core, :turn, :stop]`, measurements and metadata. Text
streams as `[:wardrik_core, :message, :delta]` while the model writes it. See
`WardrikCore.Telemetry` for every event core emits.

## Your own events

Packages emit their own events through the same sink with `WardrikCore.Event.emit/4`. So a client
sees a policy's decisions alongside the agent's turns. From middleware or a tool, pass the
context. Here, the sink itself:

```elixir
WardrikCore.Event.emit({MyApp.Events, []}, [:my_app, :refused], %{}, %{agent_id: "support"})
# [:my_app, :refused]
```

The sink runs in the agent's process, as each event happens. Keep it quick: store or send the
event, and return. A durable log that numbers events for reconnecting clients belongs in a package.
