defmodule WardrikCore.Turn do
  @moduledoc false
  alias WardrikCore.Context
  alias WardrikCore.Event
  alias WardrikCore.InDoubt
  alias WardrikCore.Resume
  alias WardrikCore.ToolRunner
  alias WardrikCore.Usage

  @type checkpoint :: %{
          messages: [ReqLLM.Message.t()],
          calls: [WardrikCore.ToolCall.t()],
          rounds: non_neg_integer(),
          metadata: map(),
          private: map(),
          span: WardrikCore.Span.t(),
          measurements: map()
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
  @spec resume(Context.t(), Resume.t()) :: WardrikCore.Middleware.result()
  def resume(%Context{} = context, %Resume{} = resume) do
    context = %{with_tools(context) | resume: resume}
    Context.run(context, :turn, fn context -> reenter(context, resume) end)
  end

  @doc """
  Carries on a turn lost while its tools ran, from the checkpoint it saved. Each call may already
  have run. A call whose tool is `idempotent` is safe to repeat, so it's repeated. Any other parks
  as `:in_doubt`.
  """
  @spec recover(Context.t(), checkpoint()) :: WardrikCore.Middleware.result()
  def recover(
        %Context{} = context,
        %{messages: messages, calls: calls, rounds: rounds} = checkpoint
      ) do
    metadata = Map.merge(context.metadata, checkpoint.metadata)

    context = %{
      with_tools(context)
      | messages: messages,
        metadata: metadata,
        private: checkpoint.private,
        span: checkpoint.span,
        measurements: checkpoint.measurements
    }

    Context.run(context, :turn, fn context ->
      run_calls(context, calls, rounds, resume: InDoubt.resumes(calls))
    end)
  end

  @doc "Asks the turn running in `pid` to end at its next step."
  @spec yield(pid()) :: :ok
  def yield(pid) do
    send(pid, {__MODULE__, :yield})
    :ok
  end

  defp reenter(context, %Resume{reason: {:tool_calls, results}} = resume) do
    context = clear_resume(context)
    parked = parked_calls(results)
    calls = Enum.map(parked, fn {call, _reason} -> call end)
    {rerun, context} = ToolRunner.run(context, calls, resume: resume_each(parked, resume))

    continue(context, replace_outcomes(results, rerun), context.max_rounds)
  end

  defp reenter(context, _resume), do: loop(context, context.max_rounds)

  defp parked_calls(results) do
    for {call, {:park, reason}} <- results, do: {call, reason}
  end

  defp resume_each(parked, resume) do
    Map.new(parked, fn {call, reason} -> {call.id, %{resume | reason: reason}} end)
  end

  defp replace_outcomes(results, rerun) do
    rerun_outcomes = Map.new(rerun, fn {call, outcome} -> {call.id, outcome} end)

    Enum.map(results, fn {call, outcome} ->
      {call, Map.get(rerun_outcomes, call.id, outcome)}
    end)
  end

  defp with_tools(context) do
    tools =
      Enum.flat_map(context.capabilities, fn entry ->
        {module, opts} = Context.entry(entry)
        module.tools(context, opts)
      end)

    %{context | tools: tools}
  end

  defp loop(_context, 0), do: {:error, :max_rounds}

  defp loop(context, rounds) do
    if yield_requested?(), do: {:ok, context}, else: step(context, rounds)
  end

  defp step(context, rounds) do
    with {:ok, context} <- Context.run(context, :generate, &generate/1) do
      context = clear_resume(context)

      case tool_calls(context.response) do
        [] -> {:ok, context}
        calls -> run_tools(context, calls, rounds)
      end
    end
  end

  defp tool_calls(response) do
    response
    |> ReqLLM.Response.tool_calls()
    |> Enum.map(&WardrikCore.ToolCall.from_req_llm/1)
  end

  defp run_tools(context, calls, rounds) do
    checkpoint = %{
      messages: context.messages,
      calls: calls,
      rounds: rounds,
      metadata: context.metadata,
      private: context.private,
      span: context.span,
      measurements: context.measurements
    }

    :ok = save_checkpoint(context, checkpoint)
    run_calls(context, calls, rounds)
  end

  defp run_calls(context, calls, rounds, opts \\ []) do
    {results, context} = ToolRunner.run(context, calls, opts)
    continue(context, results, rounds)
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

  defp dispatch(%Context{on_chunk: handlers} = context, chunk) do
    streamed(context, chunk)
    Enum.each(handlers, fn handler -> handler.(chunk) end)
  end

  defp streamed(context, %ReqLLM.StreamChunk{type: type, text: text})
       when type in [:content, :thinking] do
    Event.emit(context, [:wardrik_core, :message, :delta], %{}, %{
      agent_id: context.agent_id,
      span: context.span,
      kind: type,
      text: text
    })
  end

  defp streamed(_context, _chunk), do: :ok

  defp prompt(%Context{instructions: nil, messages: messages}), do: messages

  defp prompt(%Context{instructions: instructions, messages: messages}),
    do: [ReqLLM.Context.system(instructions) | messages]

  defp generate(%Context{} = context) do
    tools = Enum.map(context.tools, fn tool -> tool.req_llm end)

    with {:ok, streamed} <- ReqLLM.stream_text(context.model, prompt(context), tools: tools),
         {:ok, response} <-
           ReqLLM.StreamResponse.process_stream(streamed, on_chunk: &dispatch(context, &1)) do
      context =
        Context.measure(
          %{context | response: response},
          Usage.measurements(response, context.model)
        )

      {:ok, append_messages(context, [response.message])}
    end
  end
end
