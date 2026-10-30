# Principals

A principal is someone or something that can act, as in IAM. An agent has its own, like a service
account. A message can come from another, and the turn that answers acts for them.

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

## Acting for someone

```elixir
alias WardrikCore.Principal

{:ok, agent} =
  WardrikCore.start_agent(
    agent_id: "support",
    model: "anthropic:claude-haiku-4-5",
    principal: %Principal{id: "agent:support"}
  )

maria = %Principal{id: "user:maria", attributes: %{org: "acme"}}
:ok = WardrikCore.ask(agent, "Open an issue for the login bug.", %{principal: maria})

[asked | _] = WardrikCore.history(agent)
asked.metadata.principal
#=> %WardrikCore.Principal{id: "user:maria", attributes: %{org: "acme"}}
```

Middleware and tools find who the turn acts for with `WardrikCore.Context.acting_for/1`: whoever
asked, or else the agent itself.

A turn only answers consecutive messages from one principal. So a shared agent never mixes two
people's authority in one turn. Every step's span records who it was for, as `"enduser.id"`.

Core passes principals on but never reads their `attributes`. Those are for packages that decide by
them, such as a vault that keys secrets by `id`.
