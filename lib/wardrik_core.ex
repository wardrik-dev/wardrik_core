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
        http_client: Req,
        llm_client: opts[:llm_client] || ReqLLM,
        capabilities: opts[:capabilities] || %{},
        middleware: opts[:middleware] || []
      )

    state = State.new(agent_id: agent_id, model: opts[:model], context: context)

    DurableServer.Supervisor.start_child(
      WardrikCore.DurableServer,
      {WardrikCore.Agent, [key: opts[:key] || agent_id, initial_state: state]}
    )
  end

  def ask(agent, text), do: GenServer.cast(agent, {:ask, text})
end
