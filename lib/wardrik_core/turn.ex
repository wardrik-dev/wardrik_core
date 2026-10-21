defmodule WardrikCore.Turn do
  @moduledoc """
  One turn of the loop.
  """
  alias WardrikCore.Context
  alias WardrikCore.ToolRunner

  @spec run(Context.t()) :: WardrikCore.Middleware.result()
  def run(%Context{} = context) do
    context = %{context | tools: Enum.flat_map(context.capabilities, & &1.tools(context))}
    Context.run(context, :turn, &loop(&1, &1.max_rounds))
  end

  defp loop(_context, 0), do: {:error, :max_rounds}

  defp loop(context, rounds) do
    with {:ok, context} <- Context.run(context, :generate, &generate/1) do
      case ReqLLM.Response.tool_calls(context.response) do
        [] -> {:ok, context}
        calls -> run_tools(context, calls, rounds)
      end
    end
  end

  defp run_tools(context, calls, rounds) do
    results = ToolRunner.run(context, calls)

    if Enum.any?(results, &match?({_call, {:park, _}}, &1)) do
      {:park, {:tool_calls, results}, context}
    else
      loop(%{context | messages: context.messages ++ ToolRunner.messages(results)}, rounds - 1)
    end
  end

  defp generate(%Context{llm_client: client, model: model, messages: messages} = context) do
    with {:ok, streamed} <- client.stream_text(model, messages, tools: context.tools),
         {:ok, response} <- ReqLLM.StreamResponse.process_stream(streamed) do
      {:ok, %{context | response: response, messages: messages ++ [response.message]}}
    end
  end
end
