defmodule WardrikCore.Tool do
  @moduledoc """
  A tool an agent may call.

  `run` answers `{:ok, answer}` or `{:error, reason}`. To report on its step, like what a paid API
  cost, it answers with the context it was given, changed:

      run: fn %{email: email}, context ->
        found = Enrich.lookup(email)
        {:ok, found, Context.measure(context, :usd, 0.01)}
      end

  A call that failed after paying answers `{:error, reason, context}`. See `WardrikCore.Context`.

  Annotations are facts about a tool that any package can read. Give them as `annotations:`, or
  with `annotate/2`:

    * `:read_only`, it changes nothing.
    * `:destructive`, what it changes can't be put back.
    * `:idempotent`, a call is safe to repeat. Repeating it leaves things as running it once did,
      like a payment sent with an idempotency key. A call lost in a crash is repeated. Without
      this, it parks as `:in_doubt` until a person answers.
    * `:open_world`, it reaches things outside the agent's own systems, like the web.
    * `:timeout`, how long a call may take, in milliseconds.
    * `:subjects`, what a call acts on, as a function of its arguments, like
      `fn args -> [args["path"]] end`.

  The first four are MCP's tool annotations. A tool that doesn't say has none of them.
  """
  use WardrikCore.Private
  alias WardrikCore.Context
  alias WardrikCore.ToolCall

  @type answer ::
          {:ok, term()}
          | {:ok, term(), Context.t()}
          | {:error, term()}
          | {:error, term(), Context.t()}
          | {:park, term()}

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          schema: keyword() | map(),
          run: (map(), Context.t() -> answer()),
          annotations: %{optional(atom()) => term()},
          private: map(),
          req_llm: ReqLLM.Tool.t()
        }

  @enforce_keys [:name, :description, :run, :req_llm]
  defstruct [:name, :description, :run, :req_llm, schema: [], annotations: %{}, private: %{}]

  @spec new!(keyword()) :: t()
  def new!(opts) do
    {annotations, opts} = Keyword.pop(opts, :annotations, [])
    tool = __MODULE__ |> struct!(Keyword.put(opts, :req_llm, nil)) |> annotate(annotations)

    req_llm =
      ReqLLM.Tool.new!(
        name: tool.name,
        description: tool.description,
        parameter_schema: tool.schema,
        callback: fn _args -> {:error, :run_by_wardrik_core} end
      )

    %{tool | req_llm: req_llm}
  end

  @doc "Adds `annotations` to the tool, like `read_only: true`. A later one replaces an earlier."
  @spec annotate(t(), keyword() | map()) :: t()
  def annotate(%__MODULE__{annotations: annotations} = tool, new),
    do: %{tool | annotations: Map.merge(annotations, Map.new(new))}

  @doc "Gets an annotation, or `default` when the tool doesn't say."
  @spec annotation(t(), atom(), term()) :: term()
  def annotation(%__MODULE__{annotations: annotations}, key, default \\ nil),
    do: Map.get(annotations, key, default)

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
