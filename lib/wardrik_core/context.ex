defmodule WardrikCore.Context do
  @moduledoc """
  The token threaded through a turn's middleware, like a `Req.Request`.
  """
  alias WardrikCore.Turn

  @type step :: :turn | :generate | {:tool_call, ReqLLM.ToolCall.t()}

  @type t() :: %__MODULE__{
          agent_id: String.t(),
          model: LLMDB.Model.t() | String.t(),
          step: step() | nil,
          messages: [ReqLLM.Message.t()],
          response: ReqLLM.Response.t() | {:ok, term()} | {:error, term()} | nil,
          capabilities: [module()],
          tools: [WardrikCore.Tool.t()],
          middleware: [module()],
          max_rounds: pos_integer(),
          timeout: timeout(),
          resume: {reason :: term(), input :: term()} | nil,
          checkpoint: (Turn.checkpoint() -> :ok) | nil,
          metadata: map()
        }

  defstruct [
    :agent_id,
    :model,
    :step,
    :response,
    :resume,
    :checkpoint,
    messages: [],
    capabilities: [],
    tools: [],
    middleware: [],
    max_rounds: 25,
    timeout: :infinity,
    metadata: %{}
  ]

  def new(opts) do
    struct!(__MODULE__, opts)
  end

  @doc "Runs `fun` wrapped in the context's middleware, first in the list outermost."
  @spec run(t(), WardrikCore.Middleware.next()) :: WardrikCore.Middleware.result()
  def run(%__MODULE__{middleware: middleware} = context, fun) do
    middleware
    |> Enum.reverse()
    |> Enum.reduce(fun, fn mod, next -> &mod.call(&1, next) end)
    |> then(& &1.(context))
  end

  @doc "Runs `fun` as `step`, restoring the context's own step on the way out."
  @spec run(t(), step(), WardrikCore.Middleware.next()) :: WardrikCore.Middleware.result()
  def run(%__MODULE__{step: outer} = context, step, fun) do
    case run(%{context | step: step}, fun) do
      {:ok, context} -> {:ok, %{context | step: outer}}
      {:park, reason, context} -> {:park, reason, %{context | step: outer}}
      {:error, reason} -> {:error, reason}
    end
  end
end
