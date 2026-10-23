# Run agents

Run agents under your app's supervision tree. A backend keeps each agent's state, so it survives a
restart:

```elixir
children = [
  {EKV, name: :agents, data_dir: "/var/lib/my_app/agents", cluster_size: 1},
  {WardrikCore, backend: {DurableServer.Backends.EKVStore, name: :agents}}
]

Supervisor.start_link(children, strategy: :rest_for_one)

{:ok, agent} = WardrikCore.start_agent(agent_id: "triage", model: "anthropic:claude-haiku-4-5")
:ok = WardrikCore.ask(agent, "What's on fire?")
```

## Where agents are kept

`WardrikCore` saves agents through a [durable_server](https://hexdocs.pm/durable_server) backend.
Pick one by where you want them kept:

| Backend | Keeps agents | Needs |
| --- | --- | --- |
| `MemoryStore` | In memory. They're gone when the node stops. | Nothing. For tests and trying things out. |
| `EKVStore` | On disk, and on each node when clustered. | The `ekv` dependency, and an `EKV` started before `WardrikCore`. |
| `ObjectStore` | In an S3-compatible bucket. | A `bucket`, `access_key_id`, `secret_access_key`, `s3_endpoint` and `default_region`. |
| `MirrorStore` | In two backends at once, while you move from one to the other. | The two backends. |

`MemoryStore` is core's own, as `WardrikCore.Backends.MemoryStore`. The rest come with durable_server,
under `DurableServer.Backends`.

EKV is optional. Add it only if you keep agents with it:

```elixir
{:ekv, "~> 0.4"}
```

An S3-compatible bucket needs no extra dependency:

```elixir
{WardrikCore,
 backend:
   {DurableServer.Backends.ObjectStore,
    bucket: "my-app-agents",
    access_key_id: System.fetch_env!("AWS_ACCESS_KEY_ID"),
    secret_access_key: System.fetch_env!("AWS_SECRET_ACCESS_KEY"),
    s3_endpoint: "https://s3.amazonaws.com",
    default_region: "us-east-1"}}
```

A backend of your own, like one for Postgres, implements durable_server's storage behaviour. That
behaviour isn't a public contract yet, so expect it to change between durable_server releases.

## When a node dies

Notice `ask/3` returns once the message is stored. If the node dies mid-turn, the agent picks the
message back up when it starts again. A turn lost while its tools ran carries on from its last
checkpoint, without asking the model again.

A tool call lost that way may already have run. It's repeated only if its tool is annotated
`idempotent: true`, meaning a repeat leaves things as one run did. Any other call parks as
`:in_doubt`. Answer it with `resume/3`, giving the
call's id `:approve` to run it again, or `{:deny, reason}` to tell the model why it didn't.

## Options

`start_agent/2` also takes:

| Option | Takes | Unless set |
| --- | --- | --- |
| `instructions` | the system prompt, sent with every model call and never kept in the conversation | none |
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
| `kill/2` | Stops one running tool call; the model is answered with an error, and the turn goes on |
| `resume/3` | Re-enters a parked turn, with who answered as its metadata |
| `status/1`, `history/1`, `parked/1` | What the agent is doing, has said, and waits on |
| `configure/2` | Replaces the model or settings, from the next turn |
| `stop/1` | Stops the agent until it is started again |
| `delete/2` | Stops the agent and deletes everything saved of it |
| `list/1`, `whereis/2` | Every saved agent's id, and the running agent for an id |
| `nodes/1`, `placements/1` | The cluster's nodes, and the node each saved agent runs on |
| `move/3` | Starts an agent again on another node, as it was |
