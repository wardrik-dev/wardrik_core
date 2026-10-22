defmodule WardrikCore.Context do
  @moduledoc """
  The token threaded through a turn's middleware, like a `Req.Request`.
  """
  alias WardrikCore.Turn

  @type step :: :turn | :generate | {:tool_call, ReqLLM.ToolCall.t()}
  @type entry :: module() | {module(), term()}

  @type t() :: %__MODULE__{
          agent_id: String.t(),
          model: LLMDB.Model.t() | String.t(),
          step: step() | nil,
          messages: [ReqLLM.Message.t()],
          response: ReqLLM.Response.t() | {:ok, term()} | {:error, term()} | nil,
          capabilities: [entry()],
          tools: [WardrikCore.Tool.t()],
          middleware: [entry()],
          max_rounds: pos_integer(),
          timeout: timeout(),
          resume: {reason :: term(), input :: term()} | nil,
          checkpoint: (Turn.checkpoint() -> :ok) | nil,
          on_chunk: [(ReqLLM.StreamChunk.t() -> any())],
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
    on_chunk: [],
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
    |> Enum.reduce(fun, fn entry, next ->
      {module, opts} = entry(entry)
      &module.call(&1, next, opts)
    end)
    |> then(& &1.(context))
  end

  @doc "A capability or middleware entry as `{module, opts}`."
  @spec entry(entry()) :: {module(), term()}
  def entry({module, opts}) when is_atom(module), do: {module, opts}
  def entry(module) when is_atom(module), do: {module, []}

  @doc "Runs `fun` as `step`, restoring the outer `step` and `on_chunk` on the way out."
  @spec run(t(), step(), WardrikCore.Middleware.next()) :: WardrikCore.Middleware.result()
  def run(%__MODULE__{} = context, step, fun) do
    outer = Map.take(context, [:step, :on_chunk])

    case run(%{context | step: step}, fun) do
      {:ok, context} -> {:ok, Map.merge(context, outer)}
      {:park, reason, context} -> {:park, reason, Map.merge(context, outer)}
      {:error, reason} -> {:error, reason}
    end
  end
end
