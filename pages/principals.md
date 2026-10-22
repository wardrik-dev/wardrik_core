# Principals

A principal is someone or something that can act, as in IAM. An agent has one of its own, like a
service account. A message can come from another, and the turn that answers acts on their behalf:

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
```

Middleware and tools find who the turn acts for with `Context.acting_for/1`: whoever asked, else
the agent itself. A turn answers the messages in a row from one principal, never two, so one shared
agent never mixes two people's authority. Every step's span says who it was for, as
`"enduser.id"`.

Core keeps principals and passes them on, but never reads their `attributes`. They're for the
packages that decide by them, like a vault that keys secrets by `id`.
