defmodule WardrikCore.Agent do
  @moduledoc false
  require Logger
  use DurableServer, vsn: 1

  alias WardrikCore.Agent.State
  alias WardrikCore.Event
  alias WardrikCore.Resume
  alias WardrikCore.Span
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

    Event.emit(
      state.context,
      [:wardrik_core, :agent, :start],
      %{system_time: System.system_time()},
      %{
        agent_id: state.agent_id,
        state: state.state
      }
    )

    {:ok, state}
  end

  @impl true
  def handle_call({:ask, text, metadata}, _from, %State{} = state) do
    if state.state == :running, do: Turn.yield(state.task.pid)
    message = ReqLLM.Context.user(text, metadata)
    state = %{state | pending_messages: state.pending_messages ++ [message]}

    Event.emit(
      state.context,
      [:wardrik_core, :message, :queued],
      %{queued: length(state.pending_messages)},
      %{
        agent_id: state.agent_id,
        message: message
      }
    )

    {:reply, :ok, state, {:continue, :maybe_run}, sync: true}
  end

  def handle_call({:configure, opts}, _from, state) do
    {model, settings} = Keyword.pop(opts, :model, state.model)
    state = %{state | model: model, context: struct!(state.context, settings)}
    {:reply, :ok, state, sync: true}
  end

  def handle_call(:history, _from, state), do: {:reply, state.messages, state}
  def handle_call(:status, _from, state), do: {:reply, state.state, state}
  def handle_call(:stop, _from, state), do: {:stop, :permanent, :ok, state}

  def handle_call(
        {:resume, input, metadata},
        _from,
        %State{state: :waiting, parked: parked} = state
      ) do
    context = %{
      turn_context(state, parked.messages, parked.span)
      | metadata: Map.merge(state.context.metadata, parked.metadata),
        measurements: parked.measurements
    }

    {:reply, :ok,
     start_turn(state, :resume, context, metadata, fn ->
       Turn.resume(context, %Resume{reason: parked.reason, input: input, metadata: metadata})
     end)}
  end

  def handle_call({:resume, _input, _metadata}, _from, state),
    do: {:reply, {:error, :not_parked}, state}

  def handle_call(:parked, _from, %State{state: :waiting, parked: parked} = state),
    do: {:reply, parked.reason, state}

  def handle_call(:parked, _from, state), do: {:reply, nil, state}

  def handle_call({:checkpoint, checkpoint}, {pid, _tag}, %State{task: %Task{pid: pid}} = state) do
    Event.emit(
      state.context,
      [:wardrik_core, :turn, :checkpoint],
      %{calls: length(checkpoint.calls)},
      %{
        agent_id: state.agent_id
      }
    )

    state = %{keep_private(state, checkpoint.private) | checkpoint: checkpoint, parked: nil}
    {:reply, :ok, state, sync: true}
  end

  def handle_call({:checkpoint, _checkpoint}, _from, state), do: {:reply, :stale, state}

  def handle_call(:interrupt, _from, %State{state: :running} = state),
    do: {:reply, :ok, stop_running(state, :interrupted), {:continue, :maybe_run}, sync: true}

  def handle_call(:interrupt, _from, %State{state: :waiting} = state) do
    Event.emit(state.context, [:wardrik_core, :turn, :dropped], %{agent_id: state.agent_id})
    {:reply, :ok, unanswered(state), {:continue, :maybe_run}, sync: true}
  end

  def handle_call(:interrupt, _from, state), do: {:reply, {:error, :idle}, state}

  @impl true
  def handle_cast(request, state) do
    Logger.warning("Agent #{state.agent_id} ignored an unknown cast: #{inspect(request)}")
    {:noreply, state}
  end

  @impl true
  def handle_continue(:maybe_run, %State{state: :due, checkpoint: checkpoint} = state) do
    context = turn_context(state, checkpoint.messages, checkpoint.span)
    {:noreply, start_turn(state, :recover, context, fn -> Turn.recover(context, checkpoint) end)}
  end

  def handle_continue(:maybe_run, %State{state: :idle, pending_messages: [_ | _]} = state) do
    {batch, rest} = State.next_batch(state.pending_messages)
    context = turn_context(state, state.messages ++ batch, Span.root())
    state = %{state | in_flight: batch, pending_messages: rest}
    {:noreply, start_turn(state, :run, context, fn -> Turn.run(context) end)}
  end

  def handle_continue(:maybe_run, state), do: {:noreply, state}

  @impl true
  def handle_info(:maybe_run, state), do: {:noreply, state, {:continue, :maybe_run}}

  def handle_info({ref, result}, %State{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    stop_turn(state, result)
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
  def terminate(reason, state) do
    if state.task, do: Task.shutdown(state.task, :brutal_kill)

    Event.emit(state.context, [:wardrik_core, :agent, :stop], %{
      agent_id: state.agent_id,
      reason: reason
    })
  end

  defp turn_context(state, messages, span) do
    agent = self()

    %{
      state.context
      | model: state.model,
        messages: messages,
        span: span,
        checkpoint: fn checkpoint ->
          GenServer.call(agent, {:checkpoint, checkpoint}, :timer.seconds(30))
        end
    }
  end

  defp start_turn(state, kind, context, metadata \\ %{}, fun) do
    Event.emit(
      state.context,
      [:wardrik_core, :turn, :start],
      %{system_time: System.system_time()},
      %{
        agent_id: state.agent_id,
        span: context.span,
        kind: kind,
        metadata: metadata
      }
    )

    task = Task.async(fun)
    arm_timeout(state.context.timeout, task)

    %{
      state
      | state: :running,
        task: task,
        turn_kind: kind,
        span: context.span,
        started_at: System.monotonic_time()
    }
  end

  defp arm_timeout(:infinity, _task), do: :ok
  defp arm_timeout(ms, task), do: Process.send_after(self(), {:turn_timeout, task.ref}, ms)

  defp stop_running(state, outcome) do
    case Task.shutdown(state.task, :brutal_kill) do
      {:ok, result} ->
        stop_turn(state, result)
        finished(state, result)

      _stopped ->
        stop_turn(state, outcome)
        unanswered(state)
    end
  end

  defp stop_turn(state, {:park, reason, _context}),
    do: emit_stop(state, %{outcome: :park, reason: reason})

  defp stop_turn(state, result) when is_tuple(result),
    do: emit_stop(state, %{outcome: elem(result, 0)})

  defp stop_turn(state, outcome), do: emit_stop(state, %{outcome: outcome})

  defp emit_stop(state, ended) do
    Event.emit(
      state.context,
      [:wardrik_core, :turn, :stop],
      %{duration: System.monotonic_time() - state.started_at},
      Map.merge(%{agent_id: state.agent_id, span: state.span, kind: state.turn_kind}, ended)
    )
  end

  defp finished(state, {:ok, context}),
    do: %{
      keep_private(state, context.private)
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
      keep_private(state, context.private)
      | state: :waiting,
        task: nil,
        checkpoint: nil,
        parked: %{
          reason: reason,
          messages: context.messages,
          metadata: context.metadata,
          span: context.span,
          measurements: context.measurements
        }
    }
  end

  defp finished(state, {:error, reason}) do
    Logger.error("Turn failed for agent #{state.agent_id}: #{inspect(reason)}")
    unanswered(state)
  end

  defp keep_private(state, private), do: put_in(state.context.private, private)

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
