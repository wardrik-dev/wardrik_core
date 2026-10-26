defmodule WardrikCore.ToolRunner do
  @moduledoc false
  alias WardrikCore.Context
  alias WardrikCore.Event
  alias WardrikCore.InDoubt
  alias WardrikCore.Tool
  alias WardrikCore.ToolCall

  @timeout :timer.minutes(3)
  @max_concurrency 8

  @type outcome :: {:ok, term()} | {:error, term()} | {:park, term()}

  @doc """
  Runs `calls` and answers each, in order. Adds what they measured to the context.
  """
  @spec run(Context.t(), [ToolCall.t()], keyword()) :: {[{ToolCall.t(), outcome()}], Context.t()}
  def run(%Context{} = context, calls, opts \\ []) do
    ran = run_each(%{context | measurements: %{}}, calls, opts)
    results = Enum.map(ran, fn {call, outcome, _measured} -> {call, outcome} end)

    measured =
      Enum.reduce(ran, context, fn {_call, _outcome, measured}, context ->
        Context.measure(context, measured)
      end)

    {results, measured}
  end

  defp run_each(context, calls, opts) do
    {:ok, supervisor} = Task.Supervisor.start_link()

    try do
      supervisor
      |> stream(context, calls, opts)
      |> Enum.zip_with(calls, fn
        {:ok, {outcome, measured}}, call -> {call, outcome, measured}
        {:exit, reason}, call -> {call, exited(context, call, reason), %{}}
      end)
    after
      Supervisor.stop(supervisor)
    end
  end

  defp stream(supervisor, context, calls, opts) do
    resume = Keyword.get(opts, :resume, %{})

    Task.Supervisor.async_stream_nolink(
      supervisor,
      calls,
      &call(%{context | resume: Map.get(resume, &1.id)}, &1),
      ordered: true,
      max_concurrency: Keyword.get(opts, :max_concurrency, @max_concurrency),
      timeout: Keyword.get_lazy(opts, :timeout, fn -> timeout(context.tools, calls) end),
      on_timeout: :kill_task
    )
  end

  @doc "The tool result messages for a batch's answered calls, in order, each with its labels."
  @spec messages([{ToolCall.t(), outcome()}], [Tool.t()]) :: [ReqLLM.Message.t()]
  def messages(results, tools) do
    for {call, {tag, output}} <- results, tag in [:ok, :error] do
      call.id
      |> ReqLLM.Context.tool_result(call.name, answer(tag, output))
      |> labelled(annotated(tools, call))
    end
  end

  defp annotated(tools, call) do
    case Enum.find(tools, &(&1.name == call.name)) do
      nil -> []
      tool -> Tool.annotation(tool, :labels, [])
    end
  end

  defp labelled(message, []), do: message

  defp labelled(%ReqLLM.Message{metadata: metadata} = message, labels) do
    held = Map.get(metadata, :labels, [])
    %{message | metadata: Map.put(metadata, :labels, Enum.uniq(held ++ labels))}
  end

  defp call(context, tool_call) do
    started(context, tool_call)

    case Context.run(context, {:tool_call, tool_call}, &execute/1) do
      {:ok, %Context{response: outcome, measurements: measured}} -> {outcome, measured}
      {:error, reason} -> {{:error, reason}, %{}}
      {:park, reason, %Context{measurements: measured}} -> {{:park, reason}, measured}
    end
  catch
    :error, reason -> {{:error, Exception.normalize(:error, reason, __STACKTRACE__)}, %{}}
    kind, reason -> {{:error, {kind, reason}}, %{}}
  end

  defp started(%Context{call_started: nil}, _call), do: :ok
  defp started(%Context{call_started: started}, call), do: started.(call.id)

  defp exited(context, call, reason) do
    Event.emit(context, [:wardrik_core, :tool_call, :exit], %{
      agent_id: context.agent_id,
      call: call,
      reason: reason
    })

    {:error, {:exit, reason}}
  end

  defp execute(%Context{step: {:tool_call, call}, tools: tools} = context) do
    case InDoubt.check(context, call) do
      :run -> {:ok, answered(context, Tool.call(tools, call, context))}
      answer -> {:ok, answered(context, answer)}
    end
  end

  defp answered(_context, {tag, output, %Context{} = context}) when tag in [:ok, :error],
    do: answered(context, {tag, output})

  defp answered(context, answer), do: %{context | response: answer}

  defp timeout(tools, calls) do
    names = MapSet.new(calls, & &1.name)

    tools
    |> Enum.filter(&(&1.name in names))
    |> Enum.map(&Tool.annotation(&1, :timeout, @timeout))
    |> Enum.max(fn -> @timeout end)
  end

  defp answer(:ok, output), do: output

  defp answer(:error, %ReqLLM.ToolResult{output: reason} = result),
    do: %{result | output: %{error: message(reason)}}

  defp answer(:error, reason), do: %{error: message(reason)}

  defp message(reason) when is_binary(reason), do: reason
  defp message({:exit, :killed}), do: "The call was stopped before it finished."
  defp message(%{__exception__: true} = error), do: Exception.message(error)
  defp message(%{error: error}) when is_binary(error), do: error

  defp message(reason), do: inspect(reason)
end
