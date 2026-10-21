defmodule WardrikCore.ToolRunnerTest do
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias ReqLLM.ToolCall
  alias WardrikCore.Context
  alias WardrikCore.ToolRunner

  defmodule Deny do
    @behaviour WardrikCore.Middleware

    @impl true
    def call(%Context{step: {:tool_call, call}} = context, next) do
      if ToolCall.name(call) == "echo", do: {:error, "not allowed"}, else: next.(context)
    end
  end

  defmodule Park do
    @behaviour WardrikCore.Middleware

    @impl true
    def call(context, _next), do: {:park, :needs_approval, context}
  end

  defmodule Report do
    @behaviour WardrikCore.Middleware

    @impl true
    def call(%Context{step: step, metadata: %{test: pid}} = context, next) do
      send(pid, {:step, step, self()})
      next.(context)
    end
  end

  setup do
    tools = [
      tool("echo", fn %{text: text} -> {:ok, text} end),
      tool("die", fn _ -> exit(:boom) end),
      tool("hang", fn _ -> Process.sleep(:infinity) end)
    ]

    %{context: Context.new(tools: tools, metadata: %{test: self()})}
  end

  test "answers each call in order", %{context: context} do
    calls = [call("1", "echo", %{text: "a"}), call("2", "echo", %{text: "b"})]

    assert [{%{id: "1"}, {:ok, "a"}}, {%{id: "2"}, {:ok, "b"}}] = ToolRunner.run(context, calls)
  end

  test "a tool that exits or hangs is answered with an error", %{context: context} do
    calls = [call("1", "die"), call("2", "hang"), call("3", "echo", %{text: "ok"})]

    assert [
             {_, {:error, {:exit, :boom}}},
             {_, {:error, {:exit, :timeout}}},
             {_, {:ok, "ok"}}
           ] = ToolRunner.run(context, calls, timeout: 100)
  end

  test "an unknown tool is answered with an error", %{context: context} do
    assert [{_, {:error, _}}] = ToolRunner.run(context, [call("1", "nope")])
  end

  test "middleware runs in each call's task, as a tool_call step", %{context: context} do
    call = call("1", "echo", %{text: "a"})
    ToolRunner.run(%{context | middleware: [Report]}, [call])

    assert_receive {:step, {:tool_call, ^call}, pid}
    refute pid == self()
  end

  test "middleware can deny or park a call", %{context: context} do
    calls = [call("1", "echo", %{text: "a"})]

    assert [{_, {:error, "not allowed"}}] =
             ToolRunner.run(%{context | middleware: [Deny]}, calls)

    assert [{_, {:park, :needs_approval}}] =
             ToolRunner.run(%{context | middleware: [Park]}, calls)
  end

  test "messages/1 answers every call but parked ones" do
    results = [
      {call("1", "echo"), {:ok, "a"}},
      {call("2", "echo"), {:error, "not allowed"}},
      {call("3", "echo"), {:park, :needs_approval}}
    ]

    assert [%{role: :tool, tool_call_id: "1"}, %{role: :tool, tool_call_id: "2"}] =
             ToolRunner.messages(results)
  end

  defp tool(name, callback) do
    ReqLLM.Tool.new!(
      name: name,
      description: name,
      parameter_schema: [text: [type: :string]],
      callback: callback
    )
  end

  defp call(id, name, args \\ %{}), do: ToolCall.new(id, name, JSON.encode!(args))
end
