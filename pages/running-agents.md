# Run agents

Run agents under your app's supervision tree, with their state kept in a store like EKV:

```elixir
children = [
  {EKV, name: :agents_store, data_dir: "/var/lib/my_app/agents", cluster_size: 1},
  {WardrikCore, backend: {DurableServer.Backends.EKVStore, name: :agents_store}}
]

Supervisor.start_link(children, strategy: :rest_for_one)

{:ok, agent} = WardrikCore.start_agent(agent_id: "triage", model: "anthropic:claude-haiku-4-5")
:ok = WardrikCore.ask(agent, "What's on fire?")
```

Notice `ask/3` returns once the message is stored. If the node dies mid-turn, the agent picks the
message back up when it starts again. A turn lost while its tools ran carries on from its last
checkpoint, without asking the model again.

A tool call lost that way may already have run. It's repeated only if its tool is annotated
`idempotent: true`, meaning a repeat leaves things as one run did. Any other call parks as
`:in_doubt`. Answer it with `resume/3`, giving the
call's id `:approve` to run it again, or `{:deny, reason}` to tell the model why it didn't.

In tests, start `{WardrikCore.Backends.MemoryStore, name: :agents_store}` in EKV's place and name
it as the backend. It keeps agents in memory, so they're gone when the node stops.

`start_agent/2` also takes:

| Option | Takes | Unless set |
| --- | --- | --- |
| `capabilities` | the modules that hand the agent its tools; see [Tools](tools.md) | none |
| `middleware` | what wraps every call; see [Middleware](middleware.md) | none |
| `principal` | who the agent acts as; see [Principals](principals.md) | none |
| `credentials` | where tools find credentials; see [Credentials](credentials.md) | none |
| `events` | where its events go; see [Events](events.md) | none |
| `metadata` | anything of yours, given to middleware | `%{}` |
| `timeout` | how long a turn may take | `:infinity` |
| `max_rounds` | the model calls a turn may make | 25 |


## Control a running agent

| Function | Does |
| --- | --- |
| `ask/3` | Queues a message; a running turn ends at its next step and the next turn answers it |
| `interrupt/1` | Stops the running or parked turn |
| `resume/3` | Re-enters a parked turn, with who answered as its metadata |
| `status/1`, `history/1`, `parked/1` | What the agent is doing, has said, and waits on |
| `configure/2` | Replaces the model or settings, from the next turn |
| `stop/1` | Stops the agent until it is started again |
| `list/1`, `whereis/2` | Every saved agent's id, and the running agent for an id |
