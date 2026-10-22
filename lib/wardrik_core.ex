defmodule WardrikCore do
  @moduledoc """
  Documentation for `WardrikCore`.
  """

  alias WardrikCore.Agent.State
  alias WardrikCore.Context

  defdelegate child_spec(opts), to: WardrikCore.Supervisor

  def start_agent(opts) do
    agent_id = opts[:agent_id] || "default_agent"

    context =
      Context.new(
        agent_id: agent_id,
        capabilities: opts[:capabilities] || [],
        middleware: opts[:middleware] || [],
        timeout: opts[:timeout] || :infinity
      )

    state = State.new(agent_id: agent_id, model: opts[:model], context: context)

    DurableServer.Supervisor.start_child(
      WardrikCore.DurableServer,
      {WardrikCore.Agent, [key: opts[:key] || agent_id, initial_state: state]}
    )
  end

  @doc "Queues a message, returning once it is stored. A running turn yields to it."
  @spec ask(GenServer.server(), String.t()) :: :ok
  def ask(agent, text) when is_binary(text), do: GenServer.call(agent, {:ask, text})

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
end
