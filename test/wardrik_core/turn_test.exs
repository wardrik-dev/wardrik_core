defmodule WardrikCore.TurnTest do
  use ExUnit.Case, async: true
  use Mimic

  import WardrikCore.Test.LLM

  alias WardrikCore.Context
  alias WardrikCore.Resume
  alias WardrikCore.Test.Echo
  alias WardrikCore.Test.ParkGenerate
  alias WardrikCore.Test.ParkTools
  alias WardrikCore.Turn

  defmodule Witness do
    @behaviour WardrikCore.Middleware

    @impl true
    def call(
          %Context{step: {:tool_call, _call}, resume: %Resume{} = resume} = context,
          next,
          _opts
        ) do
      send(context.metadata.test, {:resumed, resume})
      next.(context)
    end

    def call(context, next, _opts), do: next.(context)
  end

  defmodule Named do
    @behaviour WardrikCore.Capability

    @impl true
    def tools(_context, name) do
      [
        WardrikCore.Tool.new!(
          name: name,
          description: name,
          run: fn _args, _context -> {:ok, name} end
        )
      ]
    end
  end

  defmodule Stream do
    @behaviour WardrikCore.Middleware

    @impl true
    def call(%Context{step: :generate, metadata: %{test: pid}} = context, next, _opts) do
      handler = fn chunk -> send(pid, {:chunk, chunk}) end
      next.(%{context | on_chunk: [handler | context.on_chunk]})
    end

    def call(context, next, _opts), do: next.(context)
  end

  defmodule Report do
    @behaviour WardrikCore.Middleware

    @impl true
    def call(%Context{step: step, metadata: %{test: pid}} = context, next, _opts) do
      send(pid, {:step, step})
      next.(context)
    end
  end

  setup do
    stub(ReqLLM.StreamResponse, :process_stream, fn response, _opts -> {:ok, response} end)

    context =
      Context.new(
        model: "anthropic:claude-haiku-4-5",
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

  test "a {module, opts} capability gets its options", %{context: context} do
    expect(ReqLLM, :stream_text, fn _model, _messages, opts ->
      assert [%ReqLLM.Tool{name: "lookup"}] = opts[:tools]
      {:ok, answer("hello")}
    end)

    assert {:ok, _} = Turn.run(%{context | capabilities: [{Named, "lookup"}]})
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

  test "a turn asked to yield ends before asking the model", %{context: context} do
    Turn.yield(self())

    assert {:ok, %Context{response: nil, messages: [%{role: :user}]}} = Turn.run(context)
  end

  test "middleware sees each streamed chunk once per model call", %{context: context} do
    stub(ReqLLM.StreamResponse, :process_stream, fn response, opts ->
      opts[:on_chunk].(ReqLLM.StreamChunk.text("hi"))
      {:ok, response}
    end)

    ReqLLM
    |> expect(:stream_text, fn _, _, _ -> {:ok, calling([call("1", "echo", %{text: "a"})])} end)
    |> expect(:stream_text, fn _, _, _ -> {:ok, answer("done")} end)

    assert {:ok, _} = Turn.run(%{context | middleware: [Stream]})

    assert_receive {:chunk, %ReqLLM.StreamChunk{type: :content, text: "hi"}}
    assert_receive {:chunk, %ReqLLM.StreamChunk{type: :content, text: "hi"}}
    refute_receive {:chunk, _}
  end

  test "a model error fails the turn", %{context: context} do
    expect(ReqLLM, :stream_text, fn _, _, _ -> {:error, :rate_limited} end)

    assert {:error, :rate_limited} = Turn.run(context)
  end

  describe "checkpoints" do
    test "a batch is checkpointed before its tools run", %{context: context} do
      test = self()

      checkpoint = fn checkpoint ->
        send(test, {:checkpoint, checkpoint})
        :ok
      end

      ReqLLM
      |> expect(:stream_text, fn _, _, _ -> {:ok, calling([call("1", "echo", %{text: "a"})])} end)
      |> expect(:stream_text, fn _, _, _ -> {:ok, answer("done")} end)

      assert {:ok, _} = Turn.run(%{context | checkpoint: checkpoint})

      assert_receive {:checkpoint,
                      %{calls: [%{id: "1"}], rounds: 25, messages: messages, metadata: %{test: _}}}

      assert [:user, :assistant] = Enum.map(messages, & &1.role)
    end

    test "recover/2 runs the checkpointed calls without asking the model again",
         %{context: context} do
      assistant = calling([call("1", "echo", %{text: "a"})]).message

      checkpoint = %{
        messages: context.messages ++ [assistant],
        calls: Enum.map(assistant.tool_calls, &WardrikCore.ToolCall.from_req_llm/1),
        rounds: 3,
        metadata: %{trace: "t1"},
        private: %{}
      }

      expect(ReqLLM, :stream_text, fn _, messages, _ ->
        assert %{role: :tool, tool_call_id: "1"} = List.last(messages)
        {:ok, answer("done")}
      end)

      assert {:ok, %Context{messages: messages, metadata: %{trace: "t1", test: _}}} =
               Turn.recover(context, checkpoint)

      assert [:user, :assistant, :tool, :assistant] = Enum.map(messages, & &1.role)
    end
  end

  describe "resume/2" do
    setup %{context: context} do
      context = %{context | middleware: [ParkTools]}

      expect(ReqLLM, :stream_text, fn _, _, _ ->
        {:ok, calling([call("1", "echo", %{text: "a"}), call("2", "echo", %{text: "b"})])}
      end)

      {:park, parked, context} = Turn.run(context)
      %{context: context, parked: parked}
    end

    test "approved calls run and the turn carries on", %{context: context, parked: parked} do
      expect(ReqLLM, :stream_text, fn _, messages, _ ->
        assert [%{role: :tool}, %{role: :tool}] = Enum.take(messages, -2)
        {:ok, answer("done")}
      end)

      assert {:ok, %Context{messages: messages}} =
               Turn.resume(context, %Resume{
                 reason: parked,
                 input: %{"1" => :approve, "2" => :approve}
               })

      assert [:user, :assistant, :tool, :tool, :assistant] = Enum.map(messages, & &1.role)
    end

    test "denied calls are answered with the reason", %{context: context, parked: parked} do
      expect(ReqLLM, :stream_text, fn _, messages, _ ->
        assert [%{tool_call_id: "1"}, %{tool_call_id: "2", content: [%{text: text}]}] =
                 Enum.take(messages, -2)

        assert text =~ "not today"
        {:ok, answer("done")}
      end)

      assert {:ok, _} =
               Turn.resume(context, %Resume{
                 reason: parked,
                 input: %{"1" => :approve, "2" => {:deny, "not today"}}
               })
    end

    test "undecided calls park the turn again", %{context: context, parked: parked} do
      assert {:park, parked, _context} =
               Turn.resume(context, %Resume{reason: parked, input: %{"1" => :approve}})

      assert {:tool_calls, [{%{id: "1"}, {:ok, "a"}}, {%{id: "2"}, {:park, _}}]} = parked
    end

    test "each parked call sees who resumed it", %{context: context, parked: parked} do
      context = %{context | middleware: [Witness | context.middleware]}
      expect(ReqLLM, :stream_text, fn _, _, _ -> {:ok, answer("done")} end)

      resume = %Resume{
        reason: parked,
        input: %{"1" => :approve, "2" => :approve},
        metadata: %{by: "maria"}
      }

      assert {:ok, _context} = Turn.resume(context, resume)

      assert_receive {:resumed, %Resume{reason: :needs_approval, metadata: %{by: "maria"}}}
      assert_receive {:resumed, %Resume{reason: :needs_approval, metadata: %{by: "maria"}}}
    end

    test "input that names no call leaves the turn parked", %{context: context, parked: parked} do
      assert {:park, ^parked, _context} =
               Turn.resume(context, %Resume{reason: parked, input: %{}})
    end
  end

  describe "resume/3 on a parked model call" do
    test "re-runs the model call, and the next one asks again", %{context: context} do
      context = %{context | middleware: [ParkGenerate]}
      assert {:park, :spend?, context} = Turn.run(context)

      expect(ReqLLM, :stream_text, fn _, _, _ ->
        {:ok, calling([call("1", "echo", %{text: "a"})])}
      end)

      assert {:park, :spend?, %Context{messages: messages}} =
               Turn.resume(context, %Resume{reason: :spend?, input: :ok})

      assert [:user, :assistant, :tool] = Enum.map(messages, & &1.role)
    end
  end
end
