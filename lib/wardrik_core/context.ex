defmodule WardrikCore.Context do
  @moduledoc """
  The token threaded through a turn's middleware, like a `Req.Request`.

  Its private data stays with the agent from turn to turn, and through restarts. It's saved when a
  turn finishes or parks, and at each checkpoint. A turn that fails or crashes keeps only what its
  last checkpoint saved.
  """
  use WardrikCore.Private
  alias WardrikCore.Turn

  @type step :: :turn | :generate | {:tool_call, WardrikCore.ToolCall.t()}
  @type entry :: module() | {module(), term()}

  @type t() :: %__MODULE__{
          agent_id: String.t(),
          model: LLMDB.Model.t() | String.t(),
          step: step() | nil,
          messages: [ReqLLM.Message.t()],
          response: ReqLLM.Response.t() | {:ok, term()} | {:error, term()} | nil,
          usage: WardrikCore.Usage.t() | nil,
          capabilities: [entry()],
          tools: [WardrikCore.Tool.t()],
          middleware: [entry()],
          max_rounds: pos_integer(),
          timeout: timeout(),
          resume: WardrikCore.Resume.t() | nil,
          checkpoint: (Turn.checkpoint() -> :ok) | nil,
          on_chunk: [(ReqLLM.StreamChunk.t() -> any())],
          private: map(),
          metadata: map()
        }

  defstruct [
    :agent_id,
    :model,
    :step,
    :response,
    :usage,
    :resume,
    :checkpoint,
    messages: [],
    capabilities: [],
    tools: [],
    middleware: [],
    max_rounds: 25,
    timeout: :infinity,
    on_chunk: [],
    private: %{},
    metadata: %{}
  ]

  def new(opts) do
    struct!(__MODULE__, opts)
  end

  @doc "Runs `fun` through the context's middleware. The first middleware in the list runs first."
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

  @doc "Finds the tool a call names, or returns `nil`."
  @spec tool(t(), WardrikCore.ToolCall.t()) :: WardrikCore.Tool.t() | nil
  def tool(%__MODULE__{tools: tools}, %WardrikCore.ToolCall{name: name}),
    do: Enum.find(tools, &(&1.name == name))

  @doc "Turns a capability or middleware entry into `{module, opts}`."
  @spec entry(entry()) :: {module(), term()}
  def entry({module, opts}) when is_atom(module), do: {module, opts}
  def entry(module) when is_atom(module), do: {module, []}

  @doc "Runs `fun` as `step`, then puts the outer `step` and `on_chunk` back."
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
