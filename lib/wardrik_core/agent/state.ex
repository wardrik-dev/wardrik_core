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
    :state,
    :recent_message_ids,
    :last_run_at,
    :pending_messages
  ]

  def new(opts) do
    model =
      case ReqLLM.model(opts[:model]) do
        {:ok, model} -> model
        {:error, reason} -> raise ArgumentError, "Invalid model: #{inspect(reason)}"
      end

    opts = Keyword.put(opts, :model, model)

    struct(__MODULE__, opts)
  end
end
