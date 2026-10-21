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

    # DurableServer's init can't return a continue, so drain the queue by message.
    # credo:disable-for-next-line WardrikCore.Credo.Check.NoSelfSend
    send(self(), :maybe_run)

    {:ok, state}
  end

  # A resumed turn runs under the agent's config as it is now, on the messages it parked with.
  @impl true
  def handle_call({:resume, input}, _from, %State{state: :waiting, parked: parked} = state) do
    context = %{state.context | model: state.model, messages: parked.messages}
    {:reply, :ok, start_turn(state, fn -> Turn.resume(context, parked.reason, input) end)}
  end

  def handle_call({:resume, _input}, _from, state), do: {:reply, {:error, :not_parked}, state}

  def handle_call(:parked, _from, %State{state: :waiting, parked: parked} = state),
    do: {:reply, parked.reason, state}

  def handle_call(:parked, _from, state), do: {:reply, nil, state}

  @impl true
  def handle_cast({:ask, text}, %State{} = state) when is_binary(text) do
    message = ReqLLM.Context.user(text)
    state = %{state | pending_messages: state.pending_messages ++ [message]}
    {:noreply, state, {:continue, :maybe_run}, sync: true}
  end

  def handle_cast(request, state) do
    Logger.warning("Agent #{state.agent_id} ignored an unknown cast: #{inspect(request)}")
    {:noreply, state}
  end

  @impl true
  def handle_continue(:maybe_run, %State{state: :idle, pending_messages: [_ | _]} = state) do
    context = %{
      state.context
      | model: state.model,
        messages: state.messages ++ state.pending_messages,
        response: nil
    }

    state = %{state | in_flight: state.pending_messages, pending_messages: []}
    {:noreply, start_turn(state, fn -> Turn.run(context) end)}
  end

  def handle_continue(:maybe_run, state), do: {:noreply, state}

  @impl true
  def handle_info(:maybe_run, state), do: {:noreply, state, {:continue, :maybe_run}}

  def handle_info({ref, result}, %State{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    stop_turn(state, elem(result, 0))
    {:noreply, finished(state, result), {:continue, :maybe_run}, sync: true}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %State{task: %Task{ref: ref}} = state) do
    Logger.error("Turn crashed for agent #{state.agent_id}: #{inspect(reason)}")
    stop_turn(state, :crash)
    {:noreply, unanswered(state), {:continue, :maybe_run}, sync: true}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(message, state) do
    Logger.debug("Unhandled message: #{inspect(message)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %State{task: %Task{} = task}), do: Task.shutdown(task, :brutal_kill)
  def terminate(_reason, _state), do: :ok

  defp start_turn(state, fun) do
    :telemetry.execute([:wardrik_core, :turn, :start], %{system_time: System.system_time()}, %{
      agent_id: state.agent_id
    })

    task = Task.Supervisor.async(WardrikCore.TaskSupervisor, fun)
    %{state | state: :running, task: task, started_at: System.monotonic_time()}
  end

  defp stop_turn(state, outcome) do
    :telemetry.execute(
      [:wardrik_core, :turn, :stop],
      %{duration: System.monotonic_time() - state.started_at},
      %{agent_id: state.agent_id, outcome: outcome}
    )
  end

  defp finished(state, {:ok, context}),
    do: %{
      state
      | state: :idle,
        task: nil,
        parked: nil,
        in_flight: [],
        messages: context.messages
    }

  # in_flight stays until the turn ends, so a resumed turn that fails keeps them.
  defp finished(state, {:park, reason, context}) do
    Logger.info("Turn parked for agent #{state.agent_id}: #{inspect(reason)}")
    %{state | state: :waiting, task: nil, parked: %{reason: reason, messages: context.messages}}
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
        parked: nil,
        in_flight: [],
        messages: state.messages ++ state.in_flight
    }
end
