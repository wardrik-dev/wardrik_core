defmodule WardrikCore.Agent.State do
  @moduledoc """
  Represents the state of an agent in the Wardric system. This module handles
  state transitions and returns effects for callers to act upon as needed.
  """

  @type t() :: %__MODULE__{}
  @type state :: :idle | :due | :running | :waiting | :asleep

  # @recent_message_id_buffer 256

  defstruct [
    :uuid,
    :agent_id,
    :model,
    :recent_message_ids,
    :last_run_at,
    :context,
    :task,
    :started_at,
    :parked,
    state: :idle,
    messages: [],
    pending_messages: [],
    in_flight: []
  ]

  @persisted [
    :uuid,
    :agent_id,
    :recent_message_ids,
    :last_run_at,
    :messages,
    :pending_messages,
    :in_flight
  ]
  @persisted_context [
    :capabilities,
    :middleware,
    :max_rounds,
    :metadata,
    :messages
  ]

  def new(opts) do
    opts = Keyword.update!(opts, :model, &resolve_model!/1)

    struct!(__MODULE__, opts)
  end

  @doc "A plain, serializable map of what survives a restart. See `load/1`."
  @spec dump(t()) :: map()
  def dump(%__MODULE__{} = state) do
    state
    |> Map.take(@persisted)
    |> Map.merge(%{
      model: LLMDB.Model.spec(state.model),
      context: dump_context(state.context),
      parked: state.parked
    })
    |> Map.merge(requeued(state))
  end

  # A running turn dies with the process. A resumed one comes back waiting on
  # the same calls, its decisions lost; any other comes back idle, with what
  # it took queued again to be re-run.
  defp requeued(%__MODULE__{state: :running, parked: %{}}), do: %{state: :waiting}

  defp requeued(%__MODULE__{state: :running} = state),
    do: %{
      state: :idle,
      in_flight: [],
      pending_messages: state.in_flight ++ state.pending_messages
    }

  defp requeued(%__MODULE__{} = state), do: %{state: state.state}

  defp dump_context(nil), do: nil
  defp dump_context(context), do: Map.take(context, @persisted_context)

  @spec load(map()) :: t()
  def load(%{} = dumped) do
    __MODULE__
    |> struct(dumped)
    |> Map.merge(%{
      model: resolve_model!(dumped.model),
      context: load_context(dumped.context, dumped.agent_id)
    })
  end

  defp load_context(nil, _agent_id), do: nil

  defp load_context(dumped, agent_id),
    do: struct(WardrikCore.Context, Map.put(dumped, :agent_id, agent_id))

  defp resolve_model!(spec) do
    case ReqLLM.model(spec) do
      {:ok, model} -> model
      {:error, reason} -> raise ArgumentError, "Invalid model: #{inspect(reason)}"
    end
  end
end
