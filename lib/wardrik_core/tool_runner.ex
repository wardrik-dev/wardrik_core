defmodule WardrikCore.ToolRunner do
  @moduledoc false
  alias ReqLLM.ToolCall
  alias WardrikCore.Context
  alias WardrikCore.Telemetry
  alias WardrikCore.Tool

  @timeout :timer.minutes(3)
  @max_concurrency 8

  @type outcome :: {:ok, term()} | {:error, term()} | {:park, term()}

  @doc """
  Runs `calls` and answers each, in order.
  """
  @spec run(Context.t(), [ToolCall.t()], keyword()) :: [{ToolCall.t(), outcome()}]
  def run(%Context{} = context, calls, opts \\ []) do
    resume = Keyword.get(opts, :resume, %{})

    calls
    |> Task.async_stream(
      &call(%{context | resume: Map.get(resume, &1.id)}, &1),
      ordered: true,
      max_concurrency: Keyword.get(opts, :max_concurrency, @max_concurrency),
      timeout: Keyword.get_lazy(opts, :timeout, fn -> timeout(context.tools, calls) end),
      on_timeout: :kill_task
    )
    |> Enum.zip_with(calls, fn
      {:ok, outcome}, call -> {call, outcome}
      {:exit, reason}, call -> {call, exited(context, call, reason)}
    end)
  end

  @doc "The tool result messages for a batch's answered calls, in order."
  @spec messages([{ToolCall.t(), outcome()}]) :: [ReqLLM.Message.t()]
  def messages(results) do
    for {call, {tag, output}} <- results, tag in [:ok, :error] do
      ReqLLM.Context.tool_result(call.id, ToolCall.name(call), answer(tag, output))
    end
  end

  defp call(context, tool_call) do
    case Context.run(context, {:tool_call, tool_call}, &execute/1) do
      {:ok, %Context{response: outcome}} -> outcome
      {:error, reason} -> {:error, reason}
      {:park, reason, _context} -> {:park, reason}
    end
  catch
    :error, reason -> {:error, Exception.normalize(:error, reason, __STACKTRACE__)}
    kind, reason -> {:error, {kind, reason}}
  end

  defp exited(context, call, reason) do
    Telemetry.emit([:tool_call, :exit], %{agent_id: context.agent_id, call: call, reason: reason})
    {:error, {:exit, reason}}
  end

  defp execute(%Context{step: {:tool_call, call}, tools: tools} = context),
    do: {:ok, %{context | response: Tool.call(tools, call, context)}}

  defp timeout(tools, calls) do
    names = MapSet.new(calls, &ToolCall.name/1)

    tools
    |> Enum.filter(&(&1.name in names))
    |> Enum.map(&Map.get(&1.meta, :timeout, @timeout))
    |> Enum.max(fn -> @timeout end)
  end

  defp answer(:ok, output), do: output
  defp answer(:error, reason), do: %{error: message(reason)}

  defp message(reason) when is_binary(reason), do: reason
  defp message(%{__exception__: true} = error), do: Exception.message(error)
  defp message(%{error: error}) when is_binary(error), do: error

  defp message(reason), do: inspect(reason)
end
