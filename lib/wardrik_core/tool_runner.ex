defmodule WardrikCore.ToolRunner do
  @moduledoc """
  Runs a batch of tool calls concurrently.
  """
  alias ReqLLM.ToolCall
  alias WardrikCore.Context
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

    WardrikCore.TaskSupervisor
    |> Task.Supervisor.async_stream_nolink(
      calls,
      &call(%{context | resume: Map.get(resume, &1.id)}, &1),
      ordered: true,
      max_concurrency: Keyword.get(opts, :max_concurrency, @max_concurrency),
      timeout: Keyword.get_lazy(opts, :timeout, fn -> timeout(context.tools, calls) end),
      on_timeout: :kill_task
    )
    |> Enum.zip_with(calls, fn
      {:ok, outcome}, call -> {call, outcome}
      {:exit, reason}, call -> {call, {:error, {:exit, reason}}}
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

  defp message({:exit, {%{__exception__: true} = error, _stacktrace}}),
    do: Exception.message(error)

  defp message(reason), do: inspect(reason)
end
