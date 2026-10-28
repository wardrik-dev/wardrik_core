defmodule WardrikCore do
  @moduledoc """
  A durable agent runtime: agents that survive a crash, wait for a person, and run every call
  through your code.

      children = [
        {WardrikCore.Backends.MemoryStore, name: :agents},
        {WardrikCore, backend: {WardrikCore.Backends.MemoryStore, name: :agents}}
      ]

      Supervisor.start_link(children, strategy: :rest_for_one)

      {:ok, agent} =
        WardrikCore.start_agent(agent_id: "triage", model: "anthropic:claude-haiku-4-5")

      :ok = WardrikCore.ask(agent, "What's on fire?")
      WardrikCore.history(agent)

  `ask/3` returns once the message is stored. Agents kept in memory, as here, are gone when the
  node stops. With a backend that keeps them, like a disk or an S3 bucket, an agent whose node dies
  mid-turn picks the message back up when it starts again. The
  [Run agents](running-agents.html#where-agents-are-kept) guide lists the backends.

  An agent runs one turn at a time. A message that arrives mid-turn ends that turn at its next
  step, and the next turn answers it. Tools come from `WardrikCore.Capability` modules. Every
  model call and tool call runs through `WardrikCore.Middleware`.

  To run more than one instance, give the child a `name:` and pass it as the first argument.
  """

  alias WardrikCore.Agent.State
  alias WardrikCore.Context
  alias WardrikCore.Turn

  @doc """
  Runs agents under your supervision tree. Takes `:backend`, `:name` and `DurableServer.Supervisor`'s
  options. It loads every module of `wardrik_core`, `req_llm` and each app built on
  `wardrik_core` first, so a backend that decodes saved agents with `[:safe]` knows every struct
  they name.
  """
  def child_spec(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)

    spec =
      [prefix: "wardrik/"]
      |> Keyword.merge(opts)
      |> Keyword.merge(name: agents(name), backend: Keyword.fetch!(opts, :backend))
      |> DurableServer.Supervisor.child_spec()

    %{spec | id: name, start: {__MODULE__, :start_loaded, [spec.start]}}
  end

  @doc false
  def start_loaded({module, function, args}) do
    :ok = load_kept()
    apply(module, function, args)
  end

  @kept [:wardrik_core, :req_llm]

  defp load_kept do
    for {app, _description, _vsn} <- Application.loaded_applications(),
        kept?(app),
        do: app |> Application.spec(:modules) |> Code.ensure_all_loaded()

    :ok
  end

  defp kept?(app),
    do: app in @kept or :wardrik_core in (Application.spec(app, :applications) || [])

  @config [
    :instructions,
    :capabilities,
    :middleware,
    :timeout,
    :max_rounds,
    :retries,
    :principal,
    :credentials,
    :keys,
    :events,
    :metadata,
    :prices
  ]

  @doc "Starts an agent, or loads it if it was saved before."
  @spec start_agent(atom(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_agent(instance \\ __MODULE__, opts) do
    opts =
      opts
      |> Keyword.validate!([:agent_id, :model | @config])
      |> Keyword.replace_lazy(:prices, &State.canonical_prices!/1)

    agent_id = Keyword.fetch!(opts, :agent_id)
    context = Context.new([agent_id: agent_id] ++ Keyword.take(opts, @config))
    state = State.new(agent_id: agent_id, model: Keyword.fetch!(opts, :model), context: context)
    child = {WardrikCore.Agent, key: agent_id, initial_state: state}

    case DurableServer.Supervisor.start_child(agents(instance), child) do
      {:ok, {pid, _meta}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Changes an agent's model or settings. The change applies from its next turn."
  @spec configure(GenServer.server(), keyword()) :: :ok
  def configure(agent, opts) do
    opts =
      opts
      |> Keyword.validate!([:model | @config])
      |> Keyword.replace_lazy(:model, &State.canonical_spec!/1)
      |> Keyword.replace_lazy(:prices, &State.canonical_prices!/1)

    GenServer.call(agent, {:configure, opts})
  end

  @doc "Lists the id of every saved agent."
  @spec list(atom()) :: [String.t()]
  def list(instance \\ __MODULE__) do
    instance
    |> agents()
    |> DurableServer.Supervisor.stream_all_server_info()
    |> Enum.map(fn info -> info.key end)
  end

  @doc "Finds the running agent for `agent_id`, or returns `nil`."
  @spec whereis(atom(), String.t()) :: pid() | nil
  def whereis(instance \\ __MODULE__, agent_id) do
    case DurableServer.Supervisor.lookup(agents(instance), agent_id) do
      {pid, _meta} -> pid
      nil -> nil
    end
  end

  @doc """
  Queues a message and returns once it's stored. A running turn stops at its next step so the next
  turn can answer it.

  Put the `WardrikCore.Principal` who asked in `metadata` as `:principal`, and the turn that answers
  acts on their behalf. A turn answers the messages in a row from one principal, never two.

  Each message gets an `:id` in its metadata, unless you gave one.
  """
  @spec ask(GenServer.server(), String.t(), map()) :: :ok
  def ask(agent, text, metadata \\ %{}) when is_binary(text) and is_map(metadata),
    do: GenServer.call(agent, {:ask, text, metadata})

  @spec history(GenServer.server()) :: [ReqLLM.Message.t()]
  def history(agent), do: GenServer.call(agent, :history)

  @spec status(GenServer.server()) :: :idle | :running | :waiting | :due
  def status(agent), do: GenServer.call(agent, :status)

  @doc "Stops the agent until it is started again."
  @spec stop(GenServer.server()) :: :ok
  def stop(agent), do: GenServer.call(agent, :stop)

  @doc "Returns the nodes of the cluster agents run on, by name."
  @spec nodes(atom()) :: [String.t()]
  def nodes(instance \\ __MODULE__) do
    instance
    |> agents()
    |> DurableServer.Supervisor.get_cluster_nodes()
    |> Map.keys()
    |> Enum.sort()
  end

  @doc "Returns every saved agent's id, with the node it runs on, or `nil` while it isn't running."
  @spec placements(atom()) :: %{String.t() => String.t() | nil}
  def placements(instance \\ __MODULE__) do
    instance
    |> agents()
    |> DurableServer.Supervisor.stream_all_server_info()
    |> Map.new(fn info -> {info.key, placed(info)} end)
  end

  @doc """
  Starts the agent again on the node `node`, as it was. A turn it's taking ends, and what it waits
  on is abandoned.
  """
  @spec move(atom(), String.t(), String.t()) :: {:ok, pid()} | {:error, term()}
  def move(instance \\ __MODULE__, agent_id, node) do
    with {:ok, target} <- node(node, nodes(instance)),
         :ok <- saved(instance, agent_id) do
      child = {WardrikCore.Agent, key: agent_id, initial_state: %{}}

      case DurableServer.Supervisor.rehome_child(agents(instance), child, target_node: target) do
        {:ok, {pid, _meta}} -> {:ok, pid}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Stops the agent and deletes everything saved of it. Deleting an agent there isn't is `:ok`."
  @spec delete(atom(), String.t()) :: :ok | {:error, term()}
  def delete(instance \\ __MODULE__, agent_id) do
    case DurableServer.Supervisor.terminate_and_delete_child(agents(instance), agent_id) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Stops the tool call `call_id` the agent is running. The model is answered with an error for it,
  and the turn goes on.
  """
  @spec kill(GenServer.server(), String.t()) :: :ok | {:error, :not_running}
  def kill(agent, call_id) when is_binary(call_id), do: GenServer.call(agent, {:kill, call_id})

  @doc "Stops the turn that's running or parked."
  @spec interrupt(GenServer.server()) :: :ok | {:error, :idle}
  def interrupt(agent), do: GenServer.call(agent, :interrupt)

  @doc "Says why the agent is parked, or returns `nil` if it isn't."
  @spec parked(GenServer.server()) :: term() | nil
  def parked(agent), do: GenServer.call(agent, :parked)

  @doc """
  Carries on a parked turn, handing `input` to whatever parked it.

  `metadata` is yours, like who answered. It's reported on the resumed turn's start event.
  """
  @spec resume(GenServer.server(), term(), map()) :: :ok | {:error, :not_parked}
  def resume(agent, input, metadata \\ %{}) when is_map(metadata),
    do: GenServer.call(agent, {:resume, input, metadata})

  @doc """
  Asks an evaluation model named `questions` about `state`, from inside a turn.

  Returns each question's answer under its name, as the model gives it, and the call's
  measurements, to pass to `WardrikCore.Context.measure/3`.

      questions = %{"urgent" => %{type: :boolean, instructions: "Is this urgent?"}}
      {:ok, %{"urgent" => %{"probability" => p}}, measurements} =
        WardrikCore.evaluate(context, "typesafe:jev-latest", "The site is down.", questions)

  Reach for this when middleware needs a model's judgement on a call.
  """
  @spec evaluate(Context.t(), String.t(), String.t() | map(), map()) ::
          {:ok, map(), %{atom() => number()}} | {:error, term()}
  def evaluate(%Context{} = context, model, state, questions) do
    with {:ok, response} <-
           ReqLLM.evaluate(
             model,
             state,
             questions,
             WardrikCore.Keys.model_options(context, model)
           ) do
      {:ok, response.object, WardrikCore.Usage.measurements(response, model, context.prices)}
    end
  end

  @doc """
  Calls the context's model once on its instructions and messages, offering its tools, from inside
  a turn. It runs as a `:generate` step through the middleware, so policy and budgets see it as any
  other model call, and streams nothing.

  Returns the context with the `response`, its message added to `messages`, and what the call used
  measured.

      summarizing = %{context | instructions: "Summarise this conversation.", tools: []}
      {:ok, summarized} = WardrikCore.generate(summarizing)
      ReqLLM.Response.text(summarized.response)
      #=> "The user asked about..."

  Reach for this when middleware needs the agent's own model, like summarising a long history.
  """
  @spec generate(Context.t()) :: WardrikCore.Middleware.result()
  def generate(%Context{} = context), do: Turn.call_model(context)

  @doc """
  Runs `prompt` as one turn of a subagent, from inside a tool or middleware: the caller's model,
  middleware and tools, with a conversation of `prompt` alone. It can't wait on a person, so a call
  that would ends it with an error.

      {:ok, %{text: text, labels: labels}, measurements} =
        WardrikCore.subagent(context, "Find this week's releases.", name: "researcher")

  Takes `:name`, `:instructions` and `:capabilities` in place of the caller's, `:except_tools`, the
  names of tools to leave out, `:max_rounds`, and `:timeout`, how long it may run, after which it
  fails with `:timeout`, in milliseconds or `:infinity`, as unless set. A subagent that crashes
  fails with `{:exit, reason}`. Returns its answer's `text` and the `labels` of
  what it read, or why it failed, with what it measured either way, to pass to
  `WardrikCore.Context.measure/2`. While it runs, its context's `subagent` is its name, so
  middleware that counts what the caller's calls measure can leave its calls to the caller's.

  It emits `[:wardrik_core, :subagent, :started]` with its `prompt`, `:progress` as it begins each
  tool call, with how many it has, then `:completed` with its `message`, or `:failed` with its
  `error`, each with how many tool calls it made and what it measured, and each with its `agent`
  `name` and `span`. Its own steps emit nothing to the caller's events, so these are the whole of
  what a log sees of it.
  """
  @spec subagent(Context.t(), String.t(), keyword()) ::
          {:ok, %{text: String.t(), labels: [String.t()]}, map()} | {:error, term(), map()}
  def subagent(%Context{} = context, prompt, opts \\ []),
    do: WardrikCore.Subagent.run(context, prompt, opts)

  @doc """
  Returns what `model` costs in the model catalog, in US dollars per million tokens, or `nil` where
  it has no price in dollars. Give it, or one built from it, as an agent's `:prices`.

      WardrikCore.price("anthropic:claude-haiku-4-5")
      #=> [input: 1.0, output: 5.0, cache_read: 0.1, cache_write: 1.25]
  """
  @spec price(LLMDB.Model.t() | String.t()) :: WardrikCore.Usage.price() | nil
  def price(model), do: WardrikCore.Usage.price(model)

  @doc "Returns how many tokens `model` reads at once, as the model catalog gives it, or `nil`."
  @spec context_window(LLMDB.Model.t() | String.t()) :: pos_integer() | nil
  def context_window(model) do
    case ReqLLM.model(model) do
      {:ok, %LLMDB.Model{limits: %{context: window}}} when is_integer(window) -> window
      _unknown -> nil
    end
  end

  defp placed(%{running: true, node: node}), do: to_string(node)
  defp placed(_info), do: nil

  defp node(node, nodes) do
    if node in nodes,
      do: {:ok, String.to_existing_atom(node)},
      else: {:error, :no_such_node}
  end

  defp saved(instance, agent_id) do
    if agent_id in list(instance), do: :ok, else: {:error, :not_found}
  end

  defp agents(instance), do: Module.concat(instance, Agents)
end
