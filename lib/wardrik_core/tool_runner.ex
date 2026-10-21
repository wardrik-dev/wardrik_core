defmodule WardrikCore.ToolRunner do
  @moduledoc """
  Runs a batch of tool calls concurrently, each in its own task and through
  the context's middleware as a `{:tool_call, call}` step.

  Every call gets exactly one outcome: a crash, exit or timeout becomes
  `{:error, reason}` rather than taking down the turn, and the tasks die with
  the turn that started them.
  """
  alias ReqLLM.ToolCall
  alias WardrikCore.Context

  @timeout :timer.minutes(3)
  @max_concurrency 8

  @type outcome :: {:ok, term()} | {:error, term()} | {:park, term()}

  @spec run(Context.t(), [ToolCall.t()], keyword()) :: [{ToolCall.t(), outcome()}]
  def run(%Context{} = context, calls, opts \\ []) do
    WardrikCore.TaskSupervisor
    |> Task.Supervisor.async_stream_nolink(calls, &call(context, &1),
      ordered: true,
      max_concurrency: Keyword.get(opts, :max_concurrency, @max_concurrency),
      timeout: Keyword.get(opts, :timeout, @timeout),
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
    do: {:ok, %{context | response: ToolCall.execute(call, tools)}}

  defp answer(:ok, output), do: output
  defp answer(:error, reason), do: %{error: message(reason)}

  # The model reads the sentence, not the struct around it.
  defp message(reason) when is_binary(reason), do: reason
  defp message(%{__exception__: true} = error), do: Exception.message(error)
  defp message(%{error: error}) when is_binary(error), do: error
  defp message(reason), do: inspect(reason)
end
