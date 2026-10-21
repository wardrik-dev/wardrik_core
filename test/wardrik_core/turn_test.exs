defmodule WardrikCore.TurnTest do
  use ExUnit.Case, async: true
  use Mimic

  alias ReqLLM.ToolCall
  alias WardrikCore.Context
  alias WardrikCore.Turn

  defmodule Echo do
    @behaviour WardrikCore.Capability

    @impl true
    def tools(_context) do
      [
        ReqLLM.Tool.new!(
          name: "echo",
          description: "Echoes text",
          parameter_schema: [text: [type: :string]],
          callback: fn %{text: text} -> {:ok, text} end
        )
      ]
    end
  end

  defmodule ParkTools do
    @behaviour WardrikCore.Middleware

    @impl true
    def call(%Context{step: {:tool_call, _}} = context, _next),
      do: {:park, :needs_approval, context}

    def call(context, next), do: next.(context)
  end

  defmodule Report do
    @behaviour WardrikCore.Middleware

    @impl true
    def call(%Context{step: step, metadata: %{test: pid}} = context, next) do
      send(pid, {:step, step})
      next.(context)
    end
  end

  setup do
    stub(ReqLLM.StreamResponse, :process_stream, fn response -> {:ok, response} end)

    context =
      Context.new(
        model: "anthropic:claude-haiku-4-5",
        llm_client: ReqLLM,
        capabilities: [Echo],
        messages: [ReqLLM.Context.user("hi")],
        metadata: %{test: self()}
      )

    %{context: context}
  end

  test "a final answer ends the turn", %{context: context} do
    expect(ReqLLM, :stream_text, fn _model, _messages, _opts -> {:ok, answer("hello")} end)

    assert {:ok, %Context{messages: [_user, %{role: :assistant}]}} = Turn.run(context)
  end

  test "offers the capabilities' tools to the model", %{context: context} do
    expect(ReqLLM, :stream_text, fn _model, _messages, opts ->
      assert [%ReqLLM.Tool{name: "echo"}] = opts[:tools]
      {:ok, answer("hello")}
    end)

    assert {:ok, _} = Turn.run(context)
  end

  test "runs tool calls and hands their results back to the model", %{context: context} do
    ReqLLM
    |> expect(:stream_text, fn _, _, _ -> {:ok, calling([call("1", "echo", %{text: "a"})])} end)
    |> expect(:stream_text, fn _, messages, _ ->
      assert %{role: :tool, tool_call_id: "1"} = List.last(messages)
      {:ok, answer("done")}
    end)

    assert {:ok, %Context{messages: messages}} = Turn.run(context)
    assert [:user, :assistant, :tool, :assistant] = Enum.map(messages, & &1.role)
  end

  test "stops after max_rounds of tool use", %{context: context} do
    stub(ReqLLM, :stream_text, fn _, _, _ -> {:ok, calling([call("1", "echo")])} end)

    assert {:error, :max_rounds} = Turn.run(%{context | max_rounds: 2})
  end

  test "parks when a tool call parks", %{context: context} do
    expect(ReqLLM, :stream_text, fn _, _, _ -> {:ok, calling([call("1", "echo")])} end)

    assert {:park, {:tool_calls, [{%{id: "1"}, {:park, :needs_approval}}]}, %Context{}} =
             Turn.run(%{context | middleware: [ParkTools]})
  end

  test "middleware sees every step, outermost first", %{context: context} do
    ReqLLM
    |> expect(:stream_text, fn _, _, _ -> {:ok, calling([call("1", "echo", %{text: "a"})])} end)
    |> expect(:stream_text, fn _, _, _ -> {:ok, answer("done")} end)

    assert {:ok, %Context{step: nil}} = Turn.run(%{context | middleware: [Report]})

    assert_receive {:step, :turn}
    assert_receive {:step, :generate}
    assert_receive {:step, {:tool_call, %{id: "1"}}}
    assert_receive {:step, :generate}
  end

  test "a model error fails the turn", %{context: context} do
    expect(ReqLLM, :stream_text, fn _, _, _ -> {:error, :rate_limited} end)

    assert {:error, :rate_limited} = Turn.run(context)
  end

  defp answer(text), do: response(ReqLLM.Context.assistant(text))
  defp calling(calls), do: response(ReqLLM.Context.assistant("", tool_calls: calls))

  defp response(message),
    do: %ReqLLM.Response{id: "resp", model: "test", context: nil, message: message}

  defp call(id, name, args \\ %{}), do: ToolCall.new(id, name, JSON.encode!(args))
end
