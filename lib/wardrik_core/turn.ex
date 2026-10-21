defmodule WardrikCore.Turn do
  @moduledoc """
  One turn of the loop.
  """
  alias WardrikCore.Context

  @spec run(Context.t()) :: WardrikCore.Middleware.result()
  def run(%Context{} = context), do: Context.run(context, &generate/1)

  defp generate(%Context{llm_client: client, model: model, messages: messages} = context) do
    with {:ok, streamed} <- client.stream_text(model, messages),
         {:ok, response} <- ReqLLM.StreamResponse.process_stream(streamed) do
      {:ok, %{context | response: response, messages: messages ++ [response.message]}}
    end
  end
end
