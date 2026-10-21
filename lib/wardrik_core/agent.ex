defmodule WardrikCore.Agent do
  @moduledoc """
  A Durable Agent Process.
  """
  require Logger
  use DurableServer, vsn: 1

  alias WardrikCore.Agent.State
  alias WardrikCore.Turn

  @impl DurableServer
  def dump_state(%State{} = state), do: State.dump(state)

  @impl DurableServer
  def load_state(_vsn, state), do: State.load(state)

  @impl DurableServer
  def init(%State{} = state) do
    Logger.info("Initializing agent #{state.agent_id}")

    Process.flag(:trap_exit, true)

    send(self(), :maybe_run)

    {:ok, state}
  end

  @impl true
  def handle_cast({:ask, text}, %State{} = state) when is_binary(text) do
    message = ReqLLM.Context.user(text)
    state = %{state | pending_messages: state.pending_messages ++ [message]}
    {:noreply, state, {:continue, :maybe_run}}
  end

  @impl true
  def handle_continue(:maybe_run, %State{state: :idle, pending_messages: [_ | _]} = state) do
    context = %{
      state.context
      | model: state.model,
        messages: state.messages ++ state.pending_messages,
        response: nil
    }

    task = Task.Supervisor.async(WardrikCore.TaskSupervisor, fn -> Turn.run(context) end)

    {:noreply,
     %{
       state
       | state: :running,
         task: task,
         in_flight: state.pending_messages,
         pending_messages: []
     }}
  end

  def handle_continue(:maybe_run, state), do: {:noreply, state}

  @impl true
  def handle_info(:maybe_run, state), do: {:noreply, state, {:continue, :maybe_run}}

  def handle_info({ref, result}, %State{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, finished(state, result), {:continue, :maybe_run}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %State{task: %Task{ref: ref}} = state) do
    Logger.error("Turn crashed for agent #{state.agent_id}: #{inspect(reason)}")
    {:noreply, unanswered(state), {:continue, :maybe_run}}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(message, state) do
    Logger.debug("Unhandled message: #{inspect(message)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %State{task: %Task{} = task}), do: Task.shutdown(task, :brutal_kill)
  def terminate(_reason, _state), do: :ok

  defp finished(state, {:ok, context}),
    do: %{state | state: :idle, task: nil, in_flight: [], messages: context.messages}

  defp finished(state, {:park, reason, context}) do
    Logger.info("Turn parked for agent #{state.agent_id}: #{inspect(reason)}")
    %{state | state: :waiting, task: nil, in_flight: [], context: context}
  end

  defp finished(state, {:error, reason}) do
    Logger.error("Turn failed for agent #{state.agent_id}: #{inspect(reason)}")
    unanswered(state)
  end

  # Kept in history rather than requeued, so a message that always fails can't loop.
  defp unanswered(state),
    do: %{
      state
      | state: :idle,
        task: nil,
        in_flight: [],
        messages: state.messages ++ state.in_flight
    }
end
