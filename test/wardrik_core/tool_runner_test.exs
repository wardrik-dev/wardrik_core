defmodule WardrikCore.ToolRunnerTest do
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias WardrikCore.Context
  alias WardrikCore.ToolCall
  alias WardrikCore.ToolRunner

  defmodule Deny do
    @behaviour WardrikCore.Middleware

    @impl true
    def call(%Context{step: {:tool_call, call}} = context, next, _opts) do
      if call.name == "echo", do: {:error, "not allowed"}, else: next.(context)
    end
  end

  defmodule Park do
    @behaviour WardrikCore.Middleware

    @impl true
    def call(context, _next, _opts), do: {:park, :needs_approval, context}
  end

  defmodule Report do
    @behaviour WardrikCore.Middleware

    @impl true
    def call(%Context{step: step, metadata: %{test: pid}} = context, next, _opts) do
      send(pid, {:step, step, self()})
      next.(context)
    end
  end

  setup do
    tools = [
      tool("echo", fn %{text: text}, _context -> {:ok, text} end),
      tool("whoami", fn _args, %Context{step: {:tool_call, call}} -> {:ok, call.id} end),
      tool("die", fn _args, _context -> exit(:boom) end),
      tool("raise", fn _args, _context -> raise "kaput" end),
      tool("hang", fn _args, _context -> receive do: (:never -> :ok) end),
      tool("slow", fn _args, _context -> receive do: (:never -> :ok) end,
        annotations: [timeout: 50]
      )
    ]

    context =
      Context.new(
        tools: tools,
        metadata: %{test: self()}
      )

    %{context: context}
  end

  test "answers each call in order", %{context: context} do
    calls = [call("1", "echo", %{text: "a"}), call("2", "echo", %{text: "b"})]

    assert [{%{id: "1"}, {:ok, "a"}}, {%{id: "2"}, {:ok, "b"}}] = run(context, calls)
  end

  test "a tool that exits or hangs is answered with an error", %{context: context} do
    calls = [call("1", "die"), call("2", "hang"), call("3", "echo", %{text: "ok"})]

    assert [
             {_, {:error, {:exit, :boom}}},
             {_, {:error, {:exit, :timeout}}},
             {_, {:ok, "ok"}}
           ] = run(context, calls, timeout: 100)
  end

  test "a JSON Schema tool's arguments are validated", %{context: context} do
    schema = %{
      "type" => "object",
      "properties" => %{"url" => %{"type" => "string"}},
      "required" => ["url"]
    }

    fetch =
      WardrikCore.Tool.new!(
        name: "fetch",
        description: "fetch",
        schema: schema,
        run: fn %{"url" => url}, _context -> {:ok, url} end
      )

    context = %{context | tools: [fetch]}

    assert [{_, {:ok, "https://x"}}, {_, {:error, _}}] =
             run(context, [call("1", "fetch", %{url: "https://x"}), call("2", "fetch")])
  end

  test "a tool is handed its call", %{context: context} do
    assert [{_, {:ok, "7"}}] = run(context, [call("7", "whoami")])
  end

  test "a call that times out emits a tool_call exit event", %{context: context} do
    test = self()
    agent_id = "tool-exit-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      agent_id,
      [:wardrik_core, :tool_call, :exit],
      fn _event, _measurements, metadata, _config -> send(test, {:tool_exit, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(agent_id) end)

    run(%{context | agent_id: agent_id}, [call("9", "slow")])

    assert_receive {:tool_exit, %{agent_id: ^agent_id, call: %{id: "9"}, reason: :timeout}}
  end

  test "a batch runs under its tools' declared timeout", %{context: context} do
    assert [{_, {:error, {:exit, :timeout}}}] = run(context, [call("1", "slow")])
  end

  test "arguments that don't match the schema never reach the tool", %{context: context} do
    assert [{_, {:error, _}}] = run(context, [call("1", "echo", %{text: 1})])
  end

  test "a tool that raises is answered with its message", %{context: context} do
    results = run(context, [call("1", "raise")])

    assert [%{content: [%{text: text}]}] = ToolRunner.messages(results, [])
    assert text =~ "kaput"
  end

  test "an unknown tool is answered with an error", %{context: context} do
    assert [{_, {:error, _}}] = run(context, [call("1", "nope")])
  end

  test "middleware runs in each call's task, as a tool_call step", %{context: context} do
    call = call("1", "echo", %{text: "a"})
    run(%{context | middleware: [Report]}, [call])

    assert_receive {:step, {:tool_call, ^call}, pid}
    refute pid == self()
  end

  test "middleware can deny or park a call", %{context: context} do
    calls = [call("1", "echo", %{text: "a"})]

    assert [{_, {:error, "not allowed"}}] =
             run(%{context | middleware: [Deny]}, calls)

    assert [{_, {:park, :needs_approval}}] =
             run(%{context | middleware: [Park]}, calls)
  end

  test "messages/2 answers every call but parked ones" do
    results = [
      {call("1", "echo"), {:ok, "a"}},
      {call("2", "echo"), {:error, "not allowed"}},
      {call("3", "echo"), {:park, :needs_approval}}
    ]

    assert [%{role: :tool, tool_call_id: "1"}, %{role: :tool, tool_call_id: "2"}] =
             ToolRunner.messages(results, [])
  end

  test "a tool reports on its step through the context, even when it fails", %{context: context} do
    enrich = fn _args, context -> {:ok, "found", Context.measure(context, :usd, 0.01)} end
    charge = fn _args, context -> {:error, "declined", Context.measure(context, :usd, 0.02)} end
    context = %{context | tools: [tool("enrich", enrich), tool("charge", charge)]}

    calls = [call("1", "enrich"), call("2", "charge")]

    assert {[{_, {:ok, "found"}}, {_, {:error, "declined"}}], %Context{measurements: measured}} =
             ToolRunner.run(context, calls)

    assert_in_delta measured.usd, 0.03, 1.0e-9
  end

  defmodule HandSecret do
    @behaviour WardrikCore.Middleware

    @impl true
    def call(context, next, _opts),
      do: context |> Context.put_private(:secret, "s3cret") |> next.()
  end

  test "private data set during a tool call stays with that call", %{context: context} do
    context = %{context | middleware: [HandSecret]}

    assert {[{_call, {:ok, "a"}}], after_calls} =
             ToolRunner.run(context, [call("1", "echo", %{text: "a"})])

    assert nil == Context.get_private(after_calls, :secret)
  end

  defp run(context, calls, opts \\ []) do
    {results, _context} = ToolRunner.run(context, calls, opts)
    results
  end

  defp tool(name, run, opts \\ []) do
    WardrikCore.Tool.new!(
      name: name,
      description: name,
      schema: [text: [type: :string]],
      run: run,
      annotations: Keyword.get(opts, :annotations, [])
    )
  end

  defp call(id, name, args \\ %{}),
    do: %ToolCall{
      id: id,
      name: name,
      arguments: Map.new(args, fn {k, v} -> {to_string(k), v} end)
    }
end
