# Run agents

Run agents under your app's supervision tree. A backend saves each agent's state, so it survives a
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

`WardrikCore` saves agents through a [durable_server](https://hexdocs.pm/durable_server) backend:

| Backend | Keeps agents | Needs |
| --- | --- | --- |
| `MemoryStore` | In memory. Gone when the node stops. | Nothing. For tests and trying things out. |
| `EKVStore` | On disk, and on each node when clustered. | The `ekv` dependency, and `EKV` started before `WardrikCore`. |
| `ObjectStore` | In an S3-compatible bucket. | `bucket`, `access_key_id`, `secret_access_key`, `s3_endpoint` and `default_region`. |
| `MirrorStore` | In two backends at once, while you migrate between them. | The two backends. |

`MemoryStore` is `WardrikCore.Backends.MemoryStore`. The rest are under `DurableServer.Backends`.

EKV is optional. Add it only if you use `EKVStore`:

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

To write your own backend, such as one for Postgres, implement durable_server's storage behaviour.
That behaviour isn't a stable contract yet, so expect changes between durable_server releases.

## When a node dies

`ask/3` returns once the message is stored. If the node dies mid-turn, the agent picks the message
back up when it restarts. A turn lost while its tools ran resumes from its last checkpoint, without
calling the model again.

A tool call lost that way may already have run:

* If its tool is annotated `idempotent: true`, the call is repeated.
* Otherwise it parks as `:in_doubt`. Answer it with `resume/3`:

```elixir
# Run it again
WardrikCore.resume(agent, %{"call_1" => :approve})

# Tell the model it didn't run
WardrikCore.resume(agent, %{"call_1" => {:deny, "It may have run already."}})
```

## Options

`start_agent/2` also takes:

| Option | Takes | Default |
| --- | --- | --- |
| `instructions` | the system prompt, sent with every model call and never kept in the history | none |
| `capabilities` | modules that give the agent its tools. See [Tools](tools.md) | `[]` |
| `middleware` | what wraps every call. See [Middleware](middleware.md) | `[]` |
| `principal` | who the agent acts as. See [Principals](principals.md) | none |
| `credentials` | where tools find a person's credentials. See [Credentials](credentials.md) | none |
| `keys` | where code finds API keys. See [Keys](credentials.md#keys) | none |
| `events` | where its events go. See [Events](events.md) | none |
| `metadata` | anything of yours, passed to middleware | `%{}` |
| `timeout` | how long a turn may take, in milliseconds | `:infinity` |
| `max_rounds` | model calls a turn may make | `25` |
| `retries` | how failed calls are retried. See `WardrikCore.Retry` | `[]` |
| `prices` | model prices in US dollars per million tokens, by spec. Takes precedence over the model catalog | `%{}` |

```elixir
prices: %{"zai_coding_plan:glm-5.1" => [input: 1.54, output: 4.84]}
```

## Control a running agent

| Function | Does |
| --- | --- |
| `ask/3` | Queues a message. A running turn ends at its next step, and the next turn answers it |
| `interrupt/1` | Stops the running or parked turn |
| `kill/2` | Stops one running tool call. The model gets an error, and the turn goes on |
| `resume/3` | Resumes a parked turn, with who answered as metadata |
| `status/1`, `history/1`, `parked/1` | What the agent is doing, what it has said, and what it's waiting on |
| `configure/2` | Changes the model or settings, from the next turn |
| `stop/1` | Stops the agent until it's started again |
| `delete/2` | Stops the agent and deletes its saved state |
| `list/1`, `whereis/2` | Every saved agent's id, and the running agent for an id |
| `nodes/1`, `placements/1` | The cluster's nodes, and the node each saved agent runs on |
| `move/3` | Restarts an agent on another node, with its saved state |
