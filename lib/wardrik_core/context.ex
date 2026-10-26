defmodule WardrikCore.Context do
  @moduledoc """
  The token threaded through a turn's middleware.
  """
  use WardrikCore.Private

  @type step :: :turn | :generate | {:tool_call, WardrikCore.ToolCall.t()} | {:step, String.t()}
  @type entry :: module() | {module(), term()}

  @type t() :: %__MODULE__{
          agent_id: String.t(),
          model: LLMDB.Model.t() | String.t(),
          step: step() | nil,
          messages: [ReqLLM.Message.t()],
          instructions: String.t() | nil,
          response: ReqLLM.Response.t() | {:ok, term()} | {:error, term()} | nil,
          capabilities: [entry()],
          credentials: entry() | nil,
          events: entry() | nil,
          tools: [WardrikCore.Tool.t()],
          middleware: [entry()],
          max_rounds: pos_integer(),
          principal: WardrikCore.Principal.t() | nil,
          timeout: timeout(),
          resume: WardrikCore.Resume.t() | nil,
          checkpoint: (map() -> :ok) | nil,
          call_started: (String.t() -> :ok) | nil,
          on_chunk: [(ReqLLM.StreamChunk.t() -> any())],
          private: map(),
          metadata: map(),
          span: WardrikCore.Span.t() | nil,
          attributes: map(),
          measurements: %{optional(term()) => number()}
        }

  defstruct [
    :agent_id,
    :model,
    :step,
    :response,
    :span,
    :resume,
    :checkpoint,
    :call_started,
    :principal,
    :credentials,
    :events,
    :instructions,
    messages: [],
    capabilities: [],
    tools: [],
    middleware: [],
    max_rounds: 25,
    timeout: :infinity,
    on_chunk: [],
    private: %{},
    metadata: %{},
    attributes: %{},
    measurements: %{}
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

  @doc """
  Sets an attribute on the current step, as OpenTelemetry sets one on a span. Name it as
  OpenTelemetry would, like `"gen_ai.tool.name"`, or under your own prefix.
  """
  @spec attribute(t(), String.t() | atom(), term()) :: t()
  def attribute(%__MODULE__{attributes: attributes} = context, key, value),
    do: %{context | attributes: Map.put(attributes, key, value)}

  @doc """
  Adds `amount` to a measurement, like tokens or dollars spent.

  Measurements add up over the turn, and each step reports its own share when it ends. Core
  measures each model call's `input_tokens` and `output_tokens`, and its `usd` when the model has a
  price in dollars. A call to a model without one counts in `unpriced_calls`.
  """
  @spec measure(t(), term(), number()) :: t()
  def measure(%__MODULE__{measurements: measurements} = context, key, amount),
    do: %{context | measurements: Map.update(measurements, key, amount, &(&1 + amount))}

  @doc "Adds each of `measurements`, like those `WardrikCore.evaluate/4` gives."
  @spec measure(t(), map()) :: t()
  def measure(%__MODULE__{} = context, measurements) do
    Enum.reduce(measurements, context, fn {key, amount}, context ->
      measure(context, key, amount)
    end)
  end

  @doc """
  Gives who the turn acts for: the principal who sent its latest message, else the agent's own,
  else `nil`.
  """
  @spec acting_for(t()) :: WardrikCore.Principal.t() | nil
  def acting_for(%__MODULE__{messages: messages, principal: principal}) do
    messages
    |> Enum.reverse()
    |> Enum.find(fn message -> message.role == :user end)
    |> asked_by(principal)
  end

  defp asked_by(%{metadata: %{principal: %WardrikCore.Principal{} = asked}}, _agent), do: asked
  defp asked_by(_message, agent), do: agent

  @doc """
  Gives the labels of what the turn has read, or of what `messages` hold: each one in their
  metadata, once, in order. A label stays with the history it came in, until the history is cleared.

  Core carries labels and decides nothing from them. `"outside"` is content nobody on the agent's
  side wrote, such as a web page or an issue a stranger filed: it may be what asks for the next
  call.
  """
  @spec labels(t() | [ReqLLM.Message.t()]) :: [String.t()]
  def labels(%__MODULE__{messages: messages}), do: labels(messages)

  def labels(messages) when is_list(messages),
    do: messages |> Enum.flat_map(&message_labels/1) |> Enum.uniq() |> Enum.sort()

  defp message_labels(%{metadata: %{labels: labels}}), do: labels
  defp message_labels(_message), do: []

  @doc "Finds the tool a call names, or returns `nil`."
  @spec tool(t(), WardrikCore.ToolCall.t()) :: WardrikCore.Tool.t() | nil
  def tool(%__MODULE__{tools: tools}, %WardrikCore.ToolCall{name: name}),
    do: Enum.find(tools, &(&1.name == name))

  @doc "Turns a capability or middleware entry into `{module, opts}`."
  @spec entry(entry()) :: {module(), term()}
  def entry({module, opts}) when is_atom(module), do: {module, opts}
  def entry(module) when is_atom(module), do: {module, []}

  @doc """
  Runs `fun` through the middleware as `step`, in a span of its own, then puts the outer step back.

  Name a step of your own `{:step, name}`, like `{:step, "summarize"}`.
  """
  @spec run(t(), step(), WardrikCore.Middleware.next()) :: WardrikCore.Middleware.result()
  def run(%__MODULE__{} = context, step, fun) do
    outer = Map.take(context, [:step, :on_chunk, :span, :attributes])

    case WardrikCore.Telemetry.span(context, step, &run(&1, fun)) do
      {:ok, context} -> {:ok, Map.merge(context, outer)}
      {:park, reason, context} -> {:park, reason, Map.merge(context, outer)}
      {:error, reason} -> {:error, reason}
    end
  end
end
