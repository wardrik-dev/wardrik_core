# Events

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
