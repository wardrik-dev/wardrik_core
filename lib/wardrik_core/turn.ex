defmodule WardrikCore.Turn do
  @moduledoc """
  One turn of the loop.
  """
  alias WardrikCore.Context
  alias WardrikCore.ToolRunner

  @type checkpoint :: %{
          messages: [ReqLLM.Message.t()],
          calls: [ReqLLM.ToolCall.t()],
          rounds: non_neg_integer()
        }

  @spec run(Context.t()) :: WardrikCore.Middleware.result()
  def run(%Context{} = context) do
    context
    |> with_tools()
    |> Context.run(:turn, fn context -> loop(context, context.max_rounds) end)
  end

  @doc """
  Re-enters a turn where it parked.
  """
  @spec resume(Context.t(), term(), term()) :: WardrikCore.Middleware.result()
  def resume(%Context{} = context, reason, input) do
    context = %{with_tools(context) | resume: {reason, input}}
    Context.run(context, :turn, fn context -> reenter(context, reason, input) end)
  end

  @doc """
  Carries on a turn lost while its tools ran, from the checkpoint it saved.
  """
  @spec recover(Context.t(), checkpoint()) :: WardrikCore.Middleware.result()
  def recover(%Context{} = context, %{messages: messages, calls: calls, rounds: rounds}) do
    context = %{with_tools(context) | messages: messages}

    Context.run(context, :turn, fn context ->
      continue(context, ToolRunner.run(context, calls), rounds)
    end)
  end

  @doc "Asks the turn running in `pid` to end at its next step."
  @spec yield(pid()) :: :ok
  def yield(pid) do
    send(pid, {__MODULE__, :yield})
    :ok
  end

  defp reenter(context, {:tool_calls, results}, input) do
    context = clear_resume(context)
    parked = parked_calls(results)
    calls = Enum.map(parked, fn {call, _reason} -> call end)
    rerun = ToolRunner.run(context, calls, resume: resume_inputs(parked, input))

    continue(context, replace_outcomes(results, rerun), context.max_rounds)
  end

  defp reenter(context, _reason, _input), do: loop(context, context.max_rounds)

  defp parked_calls(results) do
    for {call, {:park, reason}} <- results, do: {call, reason}
  end

  defp resume_inputs(parked, input) do
    Map.new(parked, fn {call, reason} -> {call.id, {reason, input}} end)
  end

  defp replace_outcomes(results, rerun) do
    rerun_outcomes = Map.new(rerun, fn {call, outcome} -> {call.id, outcome} end)

    Enum.map(results, fn {call, outcome} ->
      {call, Map.get(rerun_outcomes, call.id, outcome)}
    end)
  end

  defp with_tools(context) do
    tools = Enum.flat_map(context.capabilities, fn capability -> capability.tools(context) end)
    %{context | tools: tools}
  end

  defp loop(_context, 0), do: {:error, :max_rounds}

  defp loop(context, rounds) do
    if yield_requested?(), do: {:ok, context}, else: step(context, rounds)
  end

  defp step(context, rounds) do
    with {:ok, context} <- Context.run(context, :generate, &generate/1) do
      context = clear_resume(context)

      case ReqLLM.Response.tool_calls(context.response) do
        [] -> {:ok, context}
        calls -> run_tools(context, calls, rounds)
      end
    end
  end

  defp run_tools(context, calls, rounds) do
    :ok = save_checkpoint(context, %{messages: context.messages, calls: calls, rounds: rounds})
    continue(context, ToolRunner.run(context, calls), rounds)
  end

  defp save_checkpoint(%Context{checkpoint: nil}, _checkpoint), do: :ok
  defp save_checkpoint(%Context{checkpoint: save}, checkpoint), do: save.(checkpoint)

  defp continue(context, results, rounds) do
    if any_parked?(results) do
      {:park, {:tool_calls, results}, context}
    else
      context
      |> append_messages(ToolRunner.messages(results))
      |> loop(rounds - 1)
    end
  end

  defp yield_requested? do
    receive do
      {__MODULE__, :yield} -> true
    after
      0 -> false
    end
  end

  defp any_parked?(results) do
    Enum.any?(results, fn {_call, outcome} -> match?({:park, _reason}, outcome) end)
  end

  defp clear_resume(context), do: %{context | resume: nil}

  defp append_messages(context, messages),
    do: %{context | messages: context.messages ++ messages}

  defp dispatch(%Context{on_chunk: handlers}, chunk),
    do: Enum.each(handlers, fn handler -> handler.(chunk) end)

  defp generate(%Context{} = context) do
    tools = Enum.map(context.tools, fn tool -> tool.req_llm end)

    with {:ok, streamed} <- ReqLLM.stream_text(context.model, context.messages, tools: tools),
         {:ok, response} <-
           ReqLLM.StreamResponse.process_stream(streamed, on_chunk: &dispatch(context, &1)) do
      context = %{context | response: response}
      {:ok, append_messages(context, [response.message])}
    end
  end
end
