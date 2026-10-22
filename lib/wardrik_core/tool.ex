defmodule WardrikCore.Tool do
  @moduledoc """
  A tool an agent may call.
  """
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

  @doc "Puts `value` in the tool's private data under `key`. Use your package's module as the key."
  @spec put_private(t(), term(), term()) :: t()
  def put_private(%__MODULE__{} = tool, key, value),
    do: %{tool | private: Map.put(tool.private, key, value)}

  @doc "Gets the value under `key` from the tool's private data, or `default`."
  @spec get_private(t(), term(), term()) :: term()
  def get_private(%__MODULE__{} = tool, key, default \\ nil),
    do: Map.get(tool.private, key, default)

  @doc "Updates the value under `key` with `fun`. Sets `default` if there's nothing there yet."
  @spec update_private(t(), term(), term(), (term() -> term())) :: t()
  def update_private(%__MODULE__{} = tool, key, default, fun),
    do: %{tool | private: Map.update(tool.private, key, default, fun)}

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
