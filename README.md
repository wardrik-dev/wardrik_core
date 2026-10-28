# WardrikCore

**Agents, governed.**

A durable agent runtime for Elixir. Agents pick up where they left off after a crash, wait for a
person when they should, and run every call through your code.

## Install

```elixir
def deps do
  [
    {:wardrik_core, "~> 0.1"}
  ]
end
```

## Start an agent

Let's run agents in your app. To begin, keep them in memory:

```elixir
children = [
  {WardrikCore.Backends.MemoryStore, name: :agents},
  {WardrikCore, backend: {WardrikCore.Backends.MemoryStore, name: :agents}}
]

Supervisor.start_link(children, strategy: :rest_for_one)

{:ok, agent} = WardrikCore.start_agent(agent_id: "triage", model: "anthropic:claude-haiku-4-5")
:ok = WardrikCore.ask(agent, "What's on fire?")
```

Agents in memory are gone when the node stops. To keep them through a restart, give `WardrikCore`
a backend that stores them, like a disk or an S3 bucket. See
[Where agents are kept](pages/running-agents.md#where-agents-are-kept).

## Guides

- [Run agents](pages/running-agents.md): crash recovery, calls in doubt, options, and controlling a
  running agent.
- [Tools](pages/tools.md): capabilities, tool annotations, and reporting what a call cost.
- [Middleware](pages/middleware.md): wrapping every call, parking for a person, and private state.
- [Principals](pages/principals.md): acting on someone's behalf.
- [Credentials](pages/credentials.md): using a person's tokens, their sign-in, and your own keys.
- [Tracing](pages/tracing.md): spans, attributes, and measurements.
- [Events](pages/events.md): following what an agent does, from a CLI, a TUI or a web page.

## What core does, and doesn't

Core runs agents durably, and gives packages seams to extend them.

- **It runs agents:** turns, tools, checkpoints, parking and resuming, and carrying on after a
  crash.
- **It gives seams:** capabilities, middleware, tool annotations, principals, credentials, keys,
  and events.
- **It leaves the rest to packages:** policy, MCP servers, storing secrets, OAuth, event logs,
  transports like HTTP, and clients.

Core changes for bugs, and for a seam no package can do without.

## License

Apache-2.0
