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

  An agent runs one turn at a time. `ask/3` returns once the message is stored, so it survives
  a crash; a message sent during a turn ends that turn at its next step and starts the next.
  Tools come from `WardrikCore.Capability` modules, and every model and tool call passes
  through `WardrikCore.Middleware`. `WardrikCore.Telemetry` lists the events an agent emits.

  Give `name:` to the child to run more than one instance, and pass it as the first argument.
  """

  alias WardrikCore.Agent.State
  alias WardrikCore.Context

  @doc "Runs agents under your tree. Takes `:backend`, `:name` and `DurableServer.Supervisor`'s options."
  def child_spec(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)

    [prefix: "wardrik/"]
    |> Keyword.merge(opts)
    |> Keyword.merge(name: agents(name), backend: Keyword.fetch!(opts, :backend))
    |> DurableServer.Supervisor.child_spec()
    |> Map.put(:id, name)
  end

  @config [:capabilities, :middleware, :timeout, :max_rounds, :metadata]

  @doc "Starts the agent `:agent_id`, or loads it as it was saved."
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

  @doc "Replaces the agent's model or settings, from its next turn."
  @spec configure(GenServer.server(), keyword()) :: :ok
  def configure(agent, opts) do
    opts =
      opts
      |> Keyword.validate!([:model | @config])
      |> Keyword.replace_lazy(:model, &State.canonical_spec!/1)

    GenServer.call(agent, {:configure, opts})
  end

  @doc "The ids of every saved agent."
  @spec list(atom()) :: [String.t()]
  def list(instance \\ __MODULE__) do
    instance
    |> agents()
    |> DurableServer.Supervisor.stream_all_server_info()
    |> Enum.map(fn info -> info.key end)
  end

  @doc "The running agent `agent_id`, or `nil`."
  @spec whereis(atom(), String.t()) :: pid() | nil
  def whereis(instance \\ __MODULE__, agent_id) do
    case DurableServer.Supervisor.lookup(agents(instance), agent_id) do
      {pid, _meta} -> pid
      nil -> nil
    end
  end

  @doc "Queues a message, returning once it is stored. A running turn yields to it."
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

  @doc "Stops the running or parked turn."
  @spec interrupt(GenServer.server()) :: :ok | {:error, :idle}
  def interrupt(agent), do: GenServer.call(agent, :interrupt)

  @doc "Why the agent is parked, or `nil`."
  @spec parked(GenServer.server()) :: term() | nil
  def parked(agent), do: GenServer.call(agent, :parked)

  @doc "Re-enters a parked turn with `input`."
  @spec resume(GenServer.server(), term()) :: :ok | {:error, :not_parked}
  def resume(agent, input), do: GenServer.call(agent, {:resume, input})

  defp agents(instance), do: Module.concat(instance, Agents)
end
