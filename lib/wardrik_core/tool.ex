defmodule WardrikCore.Tool do
  @moduledoc """
  A tool an agent may call.
  """
  use WardrikCore.Private
  alias WardrikCore.Context
  alias WardrikCore.ToolCall

  @type answer :: {:ok, term()} | {:error, term()} | {:park, term()}

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          schema: keyword() | map(),
          run: (map(), Context.t() -> answer()),
          timeout: timeout() | nil,
          private: map(),
          req_llm: ReqLLM.Tool.t()
        }

  @enforce_keys [:name, :description, :run, :req_llm]
  defstruct [:name, :description, :run, :req_llm, :timeout, schema: [], private: %{}]

  @spec new!(keyword()) :: t()
  def new!(opts) do
    tool = struct!(__MODULE__, Keyword.put(opts, :req_llm, nil))

    req_llm =
      ReqLLM.Tool.new!(
        name: tool.name,
        description: tool.description,
        parameter_schema: tool.schema,
        callback: fn _args -> {:error, :run_by_wardrik_core} end
      )

    %{tool | req_llm: req_llm}
  end

  @doc "Runs the tool a call names, with its arguments checked against the tool's schema."
  @spec call([t()], ToolCall.t(), Context.t()) :: answer()
  def call(tools, %ToolCall{} = call, %Context{} = context) do
    with %__MODULE__{} = tool <-
           Enum.find(tools, {:error, "Unknown tool: #{call.name}"}, &(&1.name == call.name)),
         {:ok, args} <- validate(tool, call.arguments) do
      tool.run.(args, context)
    end
  end

  defp validate(%__MODULE__{schema: schema}, args) when is_map(schema),
    do: ReqLLM.Schema.validate(args, schema)

  defp validate(%__MODULE__{req_llm: req_llm}, args),
    do: ReqLLM.Tool.validate_input(req_llm, args)
end
