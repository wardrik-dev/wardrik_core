defmodule WardrikCore.Tool do
  @moduledoc """
  A tool an agent may call. `run` is handed the validated arguments and the
  call's context, whose `step` holds the call. `meta` is the tool's own data,
  for middleware to read; the core reads only `:timeout`, in milliseconds.
  """
  alias ReqLLM.ToolCall
  alias WardrikCore.Context

  @type answer :: {:ok, term()} | {:error, term()} | {:park, term()}

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          schema: keyword() | map(),
          run: (map(), Context.t() -> answer()),
          meta: map(),
          req_llm: ReqLLM.Tool.t()
        }

  @enforce_keys [:name, :description, :run, :req_llm]
  defstruct [:name, :description, :run, :req_llm, schema: [], meta: %{}]

  @spec new!(keyword()) :: t()
  def new!(opts) do
    tool = struct!(__MODULE__, Keyword.put(opts, :req_llm, nil))

    req_llm =
      ReqLLM.Tool.new!(
        name: tool.name,
        description: tool.description,
        parameter_schema: tool.schema,
        # The model is offered this tool, but WardrikCore runs it; see call/3.
        callback: fn _args -> {:error, :run_by_wardrik_core} end
      )

    %{tool | req_llm: req_llm}
  end

  @doc "Runs the tool `call` names, from `tools`, with its validated arguments."
  @spec call([t()], ToolCall.t(), Context.t()) :: answer()
  def call(tools, %ToolCall{} = call, %Context{} = context) do
    name = ToolCall.name(call)

    with %__MODULE__{} = tool <-
           Enum.find(tools, {:error, "Unknown tool: #{name}"}, &(&1.name == name)),
         {:ok, args} <- ReqLLM.Tool.validate_input(tool.req_llm, ToolCall.args_map(call)) do
      tool.run.(args, context)
    end
  end
end
