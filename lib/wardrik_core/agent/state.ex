defmodule WardrikCore.Agent.State do
  @moduledoc false

  @type t() :: %__MODULE__{}
  @type state :: :idle | :due | :running | :waiting

  defstruct [
    :agent_id,
    :model,
    :context,
    :task,
    :started_at,
    :turn_kind,
    :span,
    :parked,
    :checkpoint,
    state: :idle,
    messages: [],
    pending_messages: [],
    in_flight: []
  ]

  @persisted [
    :agent_id,
    :model,
    :messages,
    :pending_messages,
    :in_flight,
    :checkpoint
  ]
  @persisted_context [
    :capabilities,
    :middleware,
    :max_rounds,
    :timeout,
    :metadata,
    :private,
    :messages
  ]

  def new(opts) do
    opts = Keyword.update!(opts, :model, &canonical_spec!/1)

    struct!(__MODULE__, opts)
  end

  @doc "A plain, serializable map of what survives a restart. See `load/1`."
  @spec dump(t()) :: map()
  def dump(%__MODULE__{} = state) do
    state
    |> Map.take(@persisted)
    |> Map.merge(%{
      context: dump_context(state.context),
      parked: state.parked
    })
    |> Map.merge(requeued(state))
  end

  defp requeued(%__MODULE__{state: :running, checkpoint: %{}}), do: %{state: :due}
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
    |> Map.put(:context, load_context(dumped.context, dumped.agent_id))
  end

  defp load_context(nil, _agent_id), do: nil

  defp load_context(dumped, agent_id),
    do: struct(WardrikCore.Context, Map.put(dumped, :agent_id, agent_id))

  @doc false
  def canonical_spec!(spec) do
    case ReqLLM.model(spec) do
      {:ok, model} -> LLMDB.Model.spec(model)
      {:error, reason} -> raise ArgumentError, "Invalid model: #{inspect(reason)}"
    end
  end
end
