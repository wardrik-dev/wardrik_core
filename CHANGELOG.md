# Changelog

## 0.1.0 (unreleased)

- Durable agents that run a model and its tools in a loop, and pick up where they left off after a
  crash, kept in any `DurableServer` backend.
- `WardrikCore.Backends.MemoryStore`, which keeps agents in memory for tests.
- Capabilities that hand an agent its tools, and middleware that wraps every turn, model call and
  tool call. Middleware can answer a step, or park it until a person resumes it.
- Tool annotations, facts about a tool any package can read, like `read_only` and `idempotent`. A
  call lost in a crash is repeated only if its tool is idempotent, and parks as `:in_doubt`
  otherwise.
- Principals, as in IAM. An agent has its own, a message can come from another, and the turn that
  answers acts on their behalf. Each step's span says who it was for, as `enduser.id`.
- `WardrikCore.Credentials`, which gives a tool the credentials of whoever its turn acts for. One
  the person hasn't granted yet parks the call on a `WardrikCore.Authorization`, and one a service
  refuses is reported with `WardrikCore.Credentials.refused/2`.
- A parked turn's stop event carries why it parked.
- `WardrikCore.Event`, which sends each event to `:telemetry` and to the agent's
  `WardrikCore.Events` sink, for clients that follow it. Packages emit theirs the same way. Text
  streams as `[:wardrik_core, :message, :delta]`.
- A tool reports on its step, like what it cost, by answering with its context.
- Every turn is a trace and every step a span, with attributes and measurements, reported as
  telemetry events.
- `WardrikCore.evaluate/4`, which asks an evaluation model questions about a step.
