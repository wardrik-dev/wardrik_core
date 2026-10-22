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

  @impl true
  def handle_call({:resume, input}, _from, %State{state: :waiting, parked: parked} = state) do
    context = turn_context(state, parked.messages)
    {:reply, :ok, start_turn(state, fn -> Turn.resume(context, parked.reason, input) end)}
  end

  def handle_call({:resume, _input}, _from, state), do: {:reply, {:error, :not_parked}, state}

  def handle_call(:parked, _from, %State{state: :waiting, parked: parked} = state),
    do: {:reply, parked.reason, state}

  def handle_call(:parked, _from, state), do: {:reply, nil, state}

  def handle_call({:checkpoint, checkpoint}, {pid, _tag}, %State{task: %Task{pid: pid}} = state),
    do: {:reply, :ok, %{state | checkpoint: checkpoint, parked: nil}, sync: true}

  def handle_call({:checkpoint, _checkpoint}, _from, state), do: {:reply, :stale, state}

  def handle_call(:interrupt, _from, %State{state: :running} = state),
    do: {:reply, :ok, stop_running(state, :interrupted), {:continue, :maybe_run}, sync: true}

  def handle_call(:interrupt, _from, %State{state: :waiting} = state),
    do: {:reply, :ok, unanswered(state), {:continue, :maybe_run}, sync: true}

  def handle_call(:interrupt, _from, state), do: {:reply, {:error, :idle}, state}

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
  def handle_continue(:maybe_run, %State{state: :due, checkpoint: checkpoint} = state) do
    context = turn_context(state, checkpoint.messages)
    {:noreply, start_turn(state, fn -> Turn.recover(context, checkpoint) end)}
  end

  def handle_continue(:maybe_run, %State{state: :idle, pending_messages: [_ | _]} = state) do
    context = turn_context(state, state.messages ++ state.pending_messages)
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

  def handle_info({:turn_timeout, ref}, %State{task: %Task{ref: ref}} = state),
    do: {:noreply, stop_running(state, :timeout), {:continue, :maybe_run}, sync: true}

  def handle_info({:turn_timeout, _ref}, state), do: {:noreply, state}

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(message, state) do
    Logger.debug("Unhandled message: #{inspect(message)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %State{task: %Task{} = task}), do: Task.shutdown(task, :brutal_kill)
  def terminate(_reason, _state), do: :ok

  defp turn_context(state, messages) do
    agent = self()

    %{
      state.context
      | model: state.model,
        messages: messages,
        checkpoint: fn checkpoint ->
          GenServer.call(agent, {:checkpoint, checkpoint}, :timer.seconds(30))
        end
    }
  end

  defp start_turn(state, fun) do
    :telemetry.execute([:wardrik_core, :turn, :start], %{system_time: System.system_time()}, %{
      agent_id: state.agent_id
    })

    task = Task.Supervisor.async(WardrikCore.TaskSupervisor, fun)
    arm_timeout(state.context.timeout, task)
    %{state | state: :running, task: task, started_at: System.monotonic_time()}
  end

  defp arm_timeout(:infinity, _task), do: :ok
  defp arm_timeout(ms, task), do: Process.send_after(self(), {:turn_timeout, task.ref}, ms)

  defp stop_running(state, outcome) do
    case Task.shutdown(state.task, :brutal_kill) do
      {:ok, result} ->
        stop_turn(state, elem(result, 0))
        finished(state, result)

      _stopped ->
        stop_turn(state, outcome)
        unanswered(state)
    end
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
        checkpoint: nil,
        in_flight: [],
        messages: context.messages
    }

  defp finished(state, {:park, reason, context}) do
    Logger.info("Turn parked for agent #{state.agent_id}: #{inspect(reason)}")

    %{
      state
      | state: :waiting,
        task: nil,
        checkpoint: nil,
        parked: %{reason: reason, messages: context.messages}
    }
  end

  defp finished(state, {:error, reason}) do
    Logger.error("Turn failed for agent #{state.agent_id}: #{inspect(reason)}")
    unanswered(state)
  end

  defp unanswered(state),
    do: %{
      state
      | state: :idle,
        task: nil,
        parked: nil,
        checkpoint: nil,
        in_flight: [],
        messages: state.messages ++ state.in_flight
    }
end
