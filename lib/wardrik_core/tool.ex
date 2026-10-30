defmodule WardrikCore.Tool do
  @moduledoc """
  A tool an agent may call.

      WardrikCore.Tool.new!(
        name: "order_status",
        description: "Say where an order is.",
        schema: [order_id: [type: :string, required: true]],
        run: fn %{order_id: id}, _context -> {:ok, MyApp.Orders.status(id)} end,
        annotations: [read_only: true]
      )

  ## Return values

  `run` takes the checked arguments and the `WardrikCore.Context`, and returns:

    * `{:ok, answer}` or `{:error, reason}`.
    * `{:ok, answer, context}` or `{:error, reason, context}` - with the context changed, to
      report on the step. A call that failed after paying returns the error form.
    * `{:park, reason}` - waits for a person.

  For example, to report what a paid API cost:

      run: fn %{email: email}, context ->
        found = Enrich.lookup(email)
        {:ok, found, WardrikCore.Context.measure(context, :usd, 0.01)}
      end

  ## Labels

  An answer can carry labels in its metadata, such as `"outside"` for text nobody on the agent's
  side wrote. The run carries the label from then on. See `WardrikCore.Context.labels/1`.

      {:ok, %ReqLLM.ToolResult{output: page, metadata: %{labels: ["outside"]}}}

  ## Annotations

  Facts about a tool that any package can read. Give them as `:annotations` to `new!/1`, or with
  `annotate/2`.

    * `:read_only` - it changes nothing.
    * `:destructive` - what it changes can't be undone.
    * `:idempotent` - a call is safe to repeat, such as a payment with an idempotency key.
    * `:open_world` - it reaches things outside the agent's own systems, such as the web.
    * `:timeout` - how long a call may take, in milliseconds.
    * `:resources` - what a call acts on, as a function of its arguments, such as
      `fn args -> [args["path"]] end`.
    * `:labels` - labels every answer carries, such as `["outside"]` for a web search.

  The first four are MCP's tool annotations. A tool that doesn't set them has none of them.

  A call to a tool that's `read_only` or `idempotent` is retried when it fails, and repeated when
  it's lost in a crash. Any other call lost that way parks as `:in_doubt` until a person answers.
  See `repeatable?/1`.
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

  @doc """
  Builds a tool.

  ## Options

    * `:name` - required.
    * `:description` - required. What the model reads to decide when to call it.
    * `:run` - required. A 2-arity function of the arguments and the context.
    * `:schema` - the arguments, as a NimbleOptions-style keyword list or a JSON Schema map.
      `[]` unless set.
    * `:annotations` - see above.

  Raises if a required option is missing.
  """
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

  @doc "Adds `annotations`, such as `read_only: true`. Replaces any with the same key."
  @spec annotate(t(), keyword() | map()) :: t()
  def annotate(%__MODULE__{annotations: annotations} = tool, new),
    do: %{tool | annotations: Map.merge(annotations, Map.new(new))}

  @doc "Returns the annotation `key`, or `default` if the tool doesn't set it."
  @spec annotation(t(), atom(), term()) :: term()
  def annotation(%__MODULE__{annotations: annotations}, key, default \\ nil),
    do: Map.get(annotations, key, default)

  @doc "Returns whether a call to the tool is safe to repeat: it's `read_only` or `idempotent`."
  @spec repeatable?(t()) :: boolean()
  def repeatable?(%__MODULE__{} = tool),
    do: annotation(tool, :read_only) == true or annotation(tool, :idempotent) == true

  @doc """
  Runs the tool `call` names, after checking its arguments against the tool's schema.

  Returns `{:error, reason}` if no tool has that name or the arguments don't match.
  """
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
