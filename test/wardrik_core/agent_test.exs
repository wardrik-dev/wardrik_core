defmodule WardrikCore.AgentTest do
  use ExUnit.Case, async: false
  use Mimic
  @moduletag :capture_log

  import WardrikCore.Test.LLM

  alias WardrikCore.Test.Echo

  defmodule Trace do
    @behaviour WardrikCore.Middleware

    @impl true
    def call(%WardrikCore.Context{step: :turn} = context, next, _opts) do
      trace = Map.get_lazy(context.metadata, :trace, fn -> System.unique_integer() end)
      send(WardrikCore.AgentTest, {:trace, trace})
      next.(put_in(context.metadata[:trace], trace))
    end

    def call(context, next, _opts), do: next.(context)
  end

  defmodule Counter do
    @behaviour WardrikCore.Middleware

    alias WardrikCore.Context

    @impl true
    def call(%Context{step: :turn} = context, next, _opts) do
      context = Context.update_private(context, __MODULE__, 1, &(&1 + 1))
      send(WardrikCore.AgentTest, {:turns, Context.get_private(context, __MODULE__)})
      next.(context)
    end

    def call(context, next, _opts), do: next.(context)
  end

  defmodule Blocking do
    @behaviour WardrikCore.Capability

    @impl true
    def tools(_context, _opts) do
      [
        WardrikCore.Tool.new!(
          name: "block",
          description: "Blocks until released",
          run: fn _args, %{step: {:tool_call, call}} ->
            send(WardrikCore.AgentTest, {:tool_running, call.id, self()})
            receive do: (:release -> {:ok, "released"})
          end,
          annotations: [idempotent: true]
        )
      ]
    end
  end

  alias WardrikCore.Principal
  alias WardrikCore.Test.ParkTools

  setup :set_mimic_global

  setup do
    handler = "agent-test-#{System.unique_integer([:positive])}"

    events = [
      [:wardrik_core, :agent, :start],
      [:wardrik_core, :agent, :stop],
      [:wardrik_core, :message, :queued],
      [:wardrik_core, :turn, :start],
      [:wardrik_core, :turn, :stop],
      [:wardrik_core, :turn, :checkpoint],
      [:wardrik_core, :turn, :dropped],
      [:wardrik_core, :step, :stop]
    ]

    :telemetry.attach_many(handler, events, &__MODULE__.handle_event/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)

    stub(ReqLLM.StreamResponse, :process_stream, fn response, _opts -> {:ok, response} end)
    :ok
  end

  def handle_event([:wardrik_core | event], _measurements, metadata, test),
    do: send(test, {event, metadata})

  test "a turn that crashes leaves the agent running and its message in history" do
    expect(ReqLLM, :stream_text, fn _, _, _ -> raise "boom" end)
    {id, agent} = start_agent()

    WardrikCore.ask(agent, "hi")
    assert_receive {[:turn, :stop], %{agent_id: ^id, outcome: :crash}}

    assert %{state: :idle, in_flight: [], messages: [%{role: :user}]} = agent_state(agent)
  end

  test "a turn that fails leaves its message in history" do
    expect(ReqLLM, :stream_text, fn _, _, _ -> {:error, :rate_limited} end)
    {id, agent} = start_agent()

    WardrikCore.ask(agent, "hi")
    assert_receive {[:turn, :stop], %{agent_id: ^id, outcome: :error}}

    assert %{state: :idle, in_flight: [], messages: [%{role: :user}]} = agent_state(agent)
  end

  test "a message survives the agent dying mid-turn, and runs when it comes back" do
    test = self()

    ReqLLM
    |> expect(:stream_text, fn _, _, _ ->
      send(test, :generating)
      receive do: (:never -> :ok)
    end)
    |> expect(:stream_text, fn _, _, _ -> {:ok, answer("done")} end)

    {id, agent} = start_agent()
    WardrikCore.ask(agent, "hi")
    assert_receive :generating

    ref = Process.monitor(agent)
    Process.exit(agent, :kill)
    assert_receive {:DOWN, ^ref, :process, _pid, :killed}

    {^id, agent} = start_agent(agent_id: id)
    assert_receive {[:turn, :stop], %{agent_id: ^id, outcome: :ok}}

    assert %{messages: messages} = agent_state(agent)
    assert [:user, :assistant] = Enum.map(messages, & &1.role)
  end

  test "an agent lost while its tools run recovers the batch without asking the model again" do
    Process.register(self(), WardrikCore.AgentTest)

    ReqLLM
    |> expect(:stream_text, fn _, _, _ -> {:ok, calling([call("call-a", "block")])} end)
    |> expect(:stream_text, fn _, messages, _ ->
      assert %{role: :tool, tool_call_id: "call-a"} = List.last(messages)
      {:ok, answer("done")}
    end)

    {id, agent} = start_agent(capabilities: [Blocking])
    WardrikCore.ask(agent, "hi")
    assert_receive {:tool_running, "call-a", _tool}
    assert_receive {[:turn, :checkpoint], %{agent_id: ^id}}

    ref = Process.monitor(agent)
    Process.exit(agent, :kill)
    assert_receive {:DOWN, ^ref, :process, _pid, :killed}

    {^id, agent} = start_agent(agent_id: id, capabilities: [Blocking])
    assert_receive {[:agent, :start], %{agent_id: ^id, state: :due}}
    assert_receive {[:turn, :start], %{agent_id: ^id, kind: :recover}}
    assert_receive {:tool_running, "call-a", tool}
    send(tool, :release)
    assert_receive {[:turn, :stop], %{agent_id: ^id, outcome: :ok}}

    assert %{state: :idle, checkpoint: nil, in_flight: [], messages: messages} =
             agent_state(agent)

    assert [:user, :assistant, :tool, :assistant] = Enum.map(messages, & &1.role)
  end

  describe "interrupt/1" do
    test "stops a running turn and its tools, then runs what was queued behind it" do
      Process.register(self(), WardrikCore.AgentTest)

      ReqLLM
      |> expect(:stream_text, fn _, _, _ -> {:ok, calling([call("call-a", "block")])} end)
      |> expect(:stream_text, fn _, messages, _ ->
        assert [:user, :user] = Enum.map(messages, & &1.role)
        {:ok, answer("done")}
      end)

      {id, agent} = start_agent(capabilities: [Blocking])
      WardrikCore.ask(agent, "first")
      assert_receive {:tool_running, "call-a", tool}
      WardrikCore.ask(agent, "second")
      tool_ref = Process.monitor(tool)

      assert :ok = WardrikCore.interrupt(agent)
      assert_receive {:DOWN, ^tool_ref, :process, _pid, _reason}
      assert_receive {[:turn, :stop], %{agent_id: ^id, outcome: :interrupted}}
      assert_receive {[:turn, :stop], %{agent_id: ^id, outcome: :ok}}

      assert %{state: :idle, checkpoint: nil, messages: messages} = agent_state(agent)
      assert [:user, :user, :assistant] = Enum.map(messages, & &1.role)
    end

    test "drops a parked turn without its unanswered tool request" do
      expect(ReqLLM, :stream_text, fn _, _, _ -> {:ok, calling([call("1", "echo")])} end)

      {id, agent} = start_agent(middleware: [ParkTools])
      WardrikCore.ask(agent, "hi")
      assert_receive {[:turn, :stop], %{agent_id: ^id, outcome: :park}}

      assert :ok = WardrikCore.interrupt(agent)
      assert_receive {[:turn, :dropped], %{agent_id: ^id}}

      assert %{state: :idle, parked: nil, messages: [%{role: :user}]} = agent_state(agent)
      assert {:error, :not_parked} = WardrikCore.resume(agent, %{"1" => :approve})
    end

    test "has nothing to stop on an idle agent" do
      {_id, agent} = start_agent()

      assert {:error, :idle} = WardrikCore.interrupt(agent)
    end
  end

  test "a turn past its timeout is stopped" do
    expect(ReqLLM, :stream_text, fn _, _, _ -> receive do: (:never -> :ok) end)

    {id, agent} = start_agent(timeout: 50)
    WardrikCore.ask(agent, "hi")

    assert_receive {[:turn, :stop], %{agent_id: ^id, outcome: :timeout}}
    assert %{state: :idle, messages: [%{role: :user}]} = agent_state(agent)
  end

  test "a message sent during a turn steers it: the turn yields, and the next one answers it" do
    Process.register(self(), WardrikCore.AgentTest)

    ReqLLM
    |> expect(:stream_text, fn _, _, _ -> {:ok, calling([call("call-a", "block")])} end)
    |> expect(:stream_text, fn _, messages, _ ->
      assert [:user, :assistant, :tool, :user] = Enum.map(messages, & &1.role)
      {:ok, answer("done")}
    end)

    {id, agent} = start_agent(capabilities: [Blocking])
    :ok = WardrikCore.ask(agent, "first")
    assert_receive {:tool_running, "call-a", tool}

    :ok = WardrikCore.ask(agent, "actually, second")
    send(tool, :release)

    assert_receive {[:turn, :stop], %{agent_id: ^id, outcome: :ok}}
    assert_receive {[:turn, :stop], %{agent_id: ^id, outcome: :ok}}

    assert [:user, :assistant, :tool, :user, :assistant] =
             agent |> WardrikCore.history() |> Enum.map(& &1.role)
  end

  test "status, history and stop" do
    test = self()

    ReqLLM
    |> expect(:stream_text, fn _, _, _ ->
      send(test, :generating)
      receive do: (:never -> :ok)
    end)
    |> expect(:stream_text, fn _, _, _ -> {:ok, answer("done")} end)

    {id, agent} = start_agent()
    assert :idle = WardrikCore.status(agent)
    assert [] = WardrikCore.history(agent)

    :ok = WardrikCore.ask(agent, "hi")
    assert_receive :generating
    assert :running = WardrikCore.status(agent)

    ref = Process.monitor(agent)
    assert :ok = WardrikCore.stop(agent)
    assert_receive {:DOWN, ^ref, :process, _pid, _reason}
    assert_receive {[:agent, :stop], %{agent_id: ^id}}

    {^id, agent} = start_agent(agent_id: id)
    assert_receive {[:turn, :stop], %{agent_id: ^id, outcome: :ok}}
    assert [:user, :assistant] = agent |> WardrikCore.history() |> Enum.map(& &1.role)
  end

  test "an ask, a park and a resume emit their lifecycle in order" do
    ReqLLM
    |> expect(:stream_text, fn _, _, _ -> {:ok, calling([call("1", "echo")])} end)
    |> expect(:stream_text, fn _, _, _ -> {:ok, answer("done")} end)

    {id, agent} = start_agent(middleware: [ParkTools])
    assert_receive {[:agent, :start], %{agent_id: ^id, state: :idle}}

    :ok = WardrikCore.ask(agent, "hi")
    assert_receive {[:message, :queued], %{agent_id: ^id}}
    assert_receive {[:turn, :start], %{agent_id: ^id, kind: :run, span: span}}
    assert_receive {[:turn, :stop], %{agent_id: ^id, kind: :run, outcome: :park}}

    :ok = WardrikCore.resume(agent, %{"1" => :approve}, %{by: "maria"})

    assert_receive {[:turn, :start],
                    %{agent_id: ^id, kind: :resume, metadata: %{by: "maria"}, span: ^span}}

    assert_receive {[:turn, :stop], %{agent_id: ^id, kind: :resume, outcome: :ok}}
  end

  test "a turn keeps its metadata across a park and resume" do
    Process.register(self(), WardrikCore.AgentTest)

    ReqLLM
    |> expect(:stream_text, fn _, _, _ -> {:ok, calling([call("1", "echo")])} end)
    |> expect(:stream_text, fn _, _, _ -> {:ok, answer("done")} end)

    {id, agent} = start_agent(middleware: [Trace, ParkTools])
    :ok = WardrikCore.ask(agent, "hi")
    assert_receive {:trace, trace}
    assert_receive {[:turn, :stop], %{agent_id: ^id, outcome: :park}}

    :ok = WardrikCore.resume(agent, %{"1" => :approve})
    assert_receive {:trace, ^trace}
    assert_receive {[:turn, :stop], %{agent_id: ^id, outcome: :ok}}
  end

  test "ask/3 metadata travels with the message" do
    expect(ReqLLM, :stream_text, fn _, _, _ -> {:ok, answer("done")} end)

    {id, agent} = start_agent()
    :ok = WardrikCore.ask(agent, "hi", %{from: "jon"})

    assert_receive {[:message, :queued], %{agent_id: ^id, message: %{metadata: %{from: "jon"}}}}
    assert_receive {[:turn, :stop], %{agent_id: ^id, outcome: :ok}}
    assert [%{metadata: %{from: "jon"}}, _answer] = WardrikCore.history(agent)
  end

  test "a turn acts on behalf of whoever asked, and each step says so" do
    expect(ReqLLM, :stream_text, fn _, _, _ -> {:ok, answer("done")} end)

    {id, agent} = start_agent(principal: %Principal{id: "agent:triage"})
    :ok = WardrikCore.ask(agent, "hi", %{principal: %Principal{id: "user:maria"}})

    assert_receive {[:step, :stop],
                    %{
                      agent_id: ^id,
                      step: :generate,
                      attributes: %{
                        "enduser.id" => "user:maria",
                        "wardrik.agent.principal.id" => "agent:triage"
                      }
                    }}
  end

  test "a turn no one asked for acts as the agent itself" do
    expect(ReqLLM, :stream_text, fn _, _, _ -> {:ok, answer("done")} end)

    {id, agent} = start_agent(principal: %Principal{id: "agent:triage"})
    :ok = WardrikCore.ask(agent, "hi")

    assert_receive {[:step, :stop],
                    %{
                      agent_id: ^id,
                      step: :generate,
                      attributes: %{"enduser.id" => "agent:triage"}
                    }}
  end

  test "whereis/1 finds a running agent by id" do
    {id, agent} = start_agent()

    assert ^agent = WardrikCore.whereis(id)
    assert nil == WardrikCore.whereis("no-such-agent")
  end

  test "start_agent/1 metadata reaches middleware" do
    Process.register(self(), WardrikCore.AgentTest)
    expect(ReqLLM, :stream_text, fn _, _, _ -> {:ok, answer("done")} end)

    {_id, agent} = start_agent(middleware: [Trace], metadata: %{trace: 42})
    :ok = WardrikCore.ask(agent, "hi")

    assert_receive {:trace, 42}
  end

  test "start_agent/1 rejects options it doesn't know" do
    assert_raise ArgumentError, fn -> start_agent(not_an_option: true) end
  end

  test "configure/2 changes the model for the next turn" do
    expect(ReqLLM, :stream_text, fn "moonshotai:kimi-k3", _, _ -> {:ok, answer("done")} end)

    {id, agent} = start_agent()
    assert :ok = WardrikCore.configure(agent, model: "moonshotai:kimi-k3", max_rounds: 3)

    :ok = WardrikCore.ask(agent, "hi")
    assert_receive {[:turn, :stop], %{agent_id: ^id, outcome: :ok}}
    assert %{model: "moonshotai:kimi-k3", context: %{max_rounds: 3}} = agent_state(agent)
  end

  test "configure/2 rejects a bad model or option in the caller" do
    {_id, agent} = start_agent()

    assert_raise ArgumentError, fn -> WardrikCore.configure(agent, model: "nope:nope") end
    assert_raise ArgumentError, fn -> WardrikCore.configure(agent, not_an_option: true) end
    assert :idle = WardrikCore.status(agent)
  end

  test "list/1 includes every saved agent" do
    {id, _agent} = start_agent()

    assert id in WardrikCore.list()
  end

  test "private data stays with the agent across turns and restarts" do
    Process.register(self(), WardrikCore.AgentTest)
    stub(ReqLLM, :stream_text, fn _, _, _ -> {:ok, answer("done")} end)

    {id, agent} = start_agent(middleware: [Counter])

    for expected <- [1, 2] do
      :ok = WardrikCore.ask(agent, "hi")
      assert_receive {:turns, ^expected}
      assert_receive {[:turn, :stop], %{agent_id: ^id, outcome: :ok}}
    end

    ref = Process.monitor(agent)
    Process.exit(agent, :kill)
    assert_receive {:DOWN, ^ref, :process, _pid, _reason}

    {^id, agent} = start_agent(agent_id: id, middleware: [Counter])
    :ok = WardrikCore.ask(agent, "hi")
    assert_receive {:turns, 3}
  end

  test "an unknown cast is ignored" do
    {_id, agent} = start_agent()

    GenServer.cast(agent, :not_a_request)

    assert nil == WardrikCore.parked(agent)
  end

  test "a parked turn is resumed through the public API" do
    ReqLLM
    |> expect(:stream_text, fn _, _, _ -> {:ok, calling([call("1", "echo", %{text: "a"})])} end)
    |> expect(:stream_text, fn _, _, _ -> {:ok, answer("done")} end)

    {id, agent} = start_agent(middleware: [ParkTools])

    assert {:error, :not_parked} = WardrikCore.resume(agent, %{"1" => :approve})

    WardrikCore.ask(agent, "hi")
    assert_receive {[:turn, :stop], %{agent_id: ^id, outcome: :park}}
    assert {:tool_calls, [{%{id: "1"}, {:park, :needs_approval}}]} = WardrikCore.parked(agent)

    assert :ok = WardrikCore.resume(agent, %{"nope" => :approve})
    assert_receive {[:turn, :stop], %{agent_id: ^id, outcome: :park}}

    assert :ok = WardrikCore.resume(agent, %{"1" => :approve})

    assert_receive {[:turn, :stop], %{agent_id: ^id, outcome: :ok}}

    assert %{state: :idle, parked: nil, in_flight: [], messages: messages} = agent_state(agent)
    assert [:user, :assistant, :tool, :assistant] = Enum.map(messages, & &1.role)
    assert nil == WardrikCore.parked(agent)
  end

  defp start_agent(opts \\ []) do
    {id, opts} =
      Keyword.pop_lazy(opts, :agent_id, fn -> "agent-#{System.unique_integer([:positive])}" end)

    {:ok, agent} =
      [agent_id: id, model: "anthropic:claude-haiku-4-5", capabilities: [Echo]]
      |> Keyword.merge(opts)
      |> WardrikCore.start_agent()

    {id, agent}
  end

  defp agent_state(agent), do: :sys.get_state(agent).user_state
end
