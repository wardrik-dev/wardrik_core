defmodule WardrikCore.Context do
  @moduledoc """
  The token threaded through a turn's middleware, like a `Req.Request`.
  """

  @type t() :: %__MODULE__{
          agent_id: String.t(),
          model: LLMDB.Model.t() | String.t(),
          http_client: module(),
          llm_client: module(),
          messages: [ReqLLM.Message.t()],
          response: ReqLLM.Response.t() | nil,
          capabilities: map(),
          middleware: [module()],
          metadata: map()
        }

  defstruct [
    :agent_id,
    :model,
    :http_client,
    :llm_client,
    :response,
    messages: [],
    capabilities: %{},
    middleware: [],
    metadata: %{}
  ]

  def new(opts) do
    struct(__MODULE__, opts)
  end

  @doc "Runs `fun` wrapped in the context's middleware, first in the list outermost."
  @spec run(t(), WardrikCore.Middleware.next()) :: WardrikCore.Middleware.result()
  def run(%__MODULE__{middleware: middleware} = context, fun) do
    middleware
    |> Enum.reverse()
    |> Enum.reduce(fun, fn mod, next -> &mod.call(&1, next) end)
    |> then(& &1.(context))
  end
end
