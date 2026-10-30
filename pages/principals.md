# Principals

A principal is someone or something that can act, as in IAM. An agent has its own, like a service
account. A message can come from another, and the turn that answers acts for them:

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

Middleware and tools find who the turn acts for with `WardrikCore.Context.acting_for/1`: whoever
asked, or else the agent itself.

A turn only answers consecutive messages from one principal. So a shared agent never mixes two
people's authority in one turn. Every step's span records who it was for, as `"enduser.id"`.

Core passes principals on but never reads their `attributes`. Those are for packages that decide by
them, such as a vault that keys secrets by `id`.
