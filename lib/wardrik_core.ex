defmodule WardrikCore do
  @moduledoc """
  Durable agents that run a model and its tools in a loop, and survive a crash.

      children = [
        {EKV, name: :agents_store, data_dir: "/var/lib/my_app/agents", cluster_size: 1},
        {WardrikCore, backend: {DurableServer.Backends.EKVStore, name: :agents_store}}
      ]

      Supervisor.start_link(children, strategy: :rest_for_one)

      {:ok, agent} =
        WardrikCore.start_agent(agent_id: "triage", model: "anthropic:claude-haiku-4-5")

      :ok = WardrikCore.ask(agent, "What's on fire?")
      WardrikCore.history(agent)

  `ask/3` returns once the message is stored. If the node dies mid-turn, the agent picks
  the message back up when it starts again.

  An agent runs one turn at a time. A message that arrives mid-turn ends that turn at its next
  step, and the next turn answers it. Tools come from `WardrikCore.Capability` modules. Every
  model call and tool call runs through `WardrikCore.Middleware`.

  To run more than one instance, give the child a `name:` and pass it as the first argument.
  """

  alias WardrikCore.Agent.State
  alias WardrikCore.Context

  @doc "Runs agents under your supervision tree. Takes `:backend`, `:name` and `DurableServer.Supervisor`'s options."
  def child_spec(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)

    [prefix: "wardrik/"]
    |> Keyword.merge(opts)
    |> Keyword.merge(name: agents(name), backend: Keyword.fetch!(opts, :backend))
    |> DurableServer.Supervisor.child_spec()
    |> Map.put(:id, name)
  end

  @config [:capabilities, :middleware, :timeout, :max_rounds, :metadata]

  @doc "Starts an agent, or loads it if it was saved before."
  @spec start_agent(atom(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_agent(instance \\ __MODULE__, opts) do
    opts = Keyword.validate!(opts, [:agent_id, :model | @config])
    agent_id = Keyword.fetch!(opts, :agent_id)
    context = Context.new([agent_id: agent_id] ++ Keyword.take(opts, @config))
    state = State.new(agent_id: agent_id, model: Keyword.fetch!(opts, :model), context: context)
    child = {WardrikCore.Agent, key: agent_id, initial_state: state}

    case DurableServer.Supervisor.start_child(agents(instance), child) do
      {:ok, {pid, _meta}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Changes an agent's model or settings. The change applies from its next turn."
  @spec configure(GenServer.server(), keyword()) :: :ok
  def configure(agent, opts) do
    opts =
      opts
      |> Keyword.validate!([:model | @config])
      |> Keyword.replace_lazy(:model, &State.canonical_spec!/1)

    GenServer.call(agent, {:configure, opts})
  end

  @doc "Lists the id of every saved agent."
  @spec list(atom()) :: [String.t()]
  def list(instance \\ __MODULE__) do
    instance
    |> agents()
    |> DurableServer.Supervisor.stream_all_server_info()
    |> Enum.map(fn info -> info.key end)
  end

  @doc "Finds the running agent for `agent_id`, or returns `nil`."
  @spec whereis(atom(), String.t()) :: pid() | nil
  def whereis(instance \\ __MODULE__, agent_id) do
    case DurableServer.Supervisor.lookup(agents(instance), agent_id) do
      {pid, _meta} -> pid
      nil -> nil
    end
  end

  @doc "Queues a message and returns once it's stored. A running turn stops at its next step so the next turn can answer it."
  @spec ask(GenServer.server(), String.t(), map()) :: :ok
  def ask(agent, text, metadata \\ %{}) when is_binary(text) and is_map(metadata),
    do: GenServer.call(agent, {:ask, text, metadata})

  @spec history(GenServer.server()) :: [ReqLLM.Message.t()]
  def history(agent), do: GenServer.call(agent, :history)

  @spec status(GenServer.server()) :: :idle | :running | :waiting | :due
  def status(agent), do: GenServer.call(agent, :status)

  @doc "Stops the agent until it is started again."
  @spec stop(GenServer.server()) :: :ok
  def stop(agent), do: GenServer.call(agent, :stop)

  @doc "Stops the turn that's running or parked."
  @spec interrupt(GenServer.server()) :: :ok | {:error, :idle}
  def interrupt(agent), do: GenServer.call(agent, :interrupt)

  @doc "Says why the agent is parked, or returns `nil` if it isn't."
  @spec parked(GenServer.server()) :: term() | nil
  def parked(agent), do: GenServer.call(agent, :parked)

  @doc """
  Carries on a parked turn, handing `input` to whatever parked it.

  `metadata` is yours, like who answered. It's reported on the resumed turn's start event.
  """
  @spec resume(GenServer.server(), term(), map()) :: :ok | {:error, :not_parked}
  def resume(agent, input, metadata \\ %{}) when is_map(metadata),
    do: GenServer.call(agent, {:resume, input, metadata})

  defp agents(instance), do: Module.concat(instance, Agents)
end
