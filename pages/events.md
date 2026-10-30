# Events

Every event an agent emits goes two places:

* `:telemetry`, for metrics and traces.
* The agent's events sink, for clients that follow it, such as a CLI, a TUI or a web page.

Give the agent a `WardrikCore.Events` module:

```elixir
defmodule MyApp.Events do
  @behaviour WardrikCore.Events

  @impl true
  def handle_event(%WardrikCore.Event{} = event, _opts) do
    Phoenix.PubSub.broadcast(MyApp.PubSub, "agent:#{event.metadata.agent_id}", event)
  end
end

WardrikCore.start_agent(
  agent_id: "triage",
  model: "anthropic:claude-haiku-4-5",
  events: {MyApp.Events, []}
)
```

Each event has a name, such as `[:wardrik_core, :turn, :stop]`, measurements and metadata. Text
streams as `[:wardrik_core, :message, :delta]` while the model writes it. See
`WardrikCore.Telemetry` for every event core emits.

Packages emit their own events through the same sink with `WardrikCore.Event.emit/4`. So a client
sees a policy's decisions alongside the agent's turns.

The sink runs in the agent's process, as each event happens. Keep it quick: store or send the
event, and return. A durable log that numbers events for reconnecting clients belongs in a package.
