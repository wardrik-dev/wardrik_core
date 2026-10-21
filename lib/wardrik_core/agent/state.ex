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
    # The running turn's Task; never persisted.
    :task,
    state: :idle,
    messages: [],
    pending_messages: [],
    # Taken from pending_messages by the running turn; cleared when it ends.
    in_flight: []
  ]

  @persisted [:uuid, :agent_id, :recent_message_ids, :last_run_at, :messages, :pending_messages]
  @persisted_context [:http_client, :llm_client, :capabilities, :middleware, :metadata, :messages]

  def new(opts) do
    opts = Keyword.update!(opts, :model, &resolve_model!/1)

    struct(__MODULE__, opts)
  end

  @doc "A plain, serializable map of what survives a restart. See `load/1`."
  @spec dump(t()) :: map()
  def dump(%__MODULE__{} = state) do
    state
    |> Map.take(@persisted)
    |> Map.merge(%{
      model: LLMDB.Model.spec(state.model),
      context: state.context && Map.take(state.context, @persisted_context)
    })
    |> Map.merge(requeued(state))
  end

  # A running turn dies with the process: it comes back idle, with what it
  # took queued again to be re-run.
  defp requeued(%__MODULE__{state: :running} = state),
    do: %{state: :idle, pending_messages: state.in_flight ++ state.pending_messages}

  defp requeued(%__MODULE__{} = state), do: %{state: state.state}

  @spec load(map()) :: t()
  def load(%{} = dumped) do
    context = dumped.context && struct(WardrikCore.Context, dumped.context)

    __MODULE__
    |> struct(dumped)
    |> Map.merge(%{
      model: resolve_model!(dumped.model),
      context: context && %{context | agent_id: dumped.agent_id}
    })
  end

  defp resolve_model!(spec) do
    case ReqLLM.model(spec) do
      {:ok, model} -> model
      {:error, reason} -> raise ArgumentError, "Invalid model: #{inspect(reason)}"
    end
  end
end
