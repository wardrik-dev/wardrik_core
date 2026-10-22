defmodule WardrikCore.AgentTest do
  use ExUnit.Case, async: false
  use Mimic
  @moduletag :capture_log

  import WardrikCore.Test.LLM

  alias WardrikCore.Test.Echo

  # A tool that tells the test it is running, then waits to be released.
  defmodule Blocking do
    @behaviour WardrikCore.Capability

    @impl true
    def tools(_context) do
      [
        WardrikCore.Tool.new!(
          name: "block",
          description: "Blocks until released",
          run: fn _args, %{step: {:tool_call, call}} ->
            send(WardrikCore.AgentTest, {:tool_running, call.id, self()})
            receive do: (:release -> {:ok, "released"})
          end
        )
      ]
    end
  end

  alias WardrikCore.Test.ParkTools

  setup :set_mimic_global

  setup do
    handler = "agent-test-#{System.unique_integer([:positive])}"
    :telemetry.attach(handler, [:wardrik_core, :turn, :stop], &__MODULE__.turn_stopped/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)

    stub(ReqLLM.StreamResponse, :process_stream, fn response -> {:ok, response} end)
    :ok
  end

  def turn_stopped(_event, _measurements, metadata, test),
    do: send(test, {:turn_stopped, metadata})

  test "a turn that crashes leaves the agent running and its message in history" do
    expect(ReqLLM, :stream_text, fn _, _, _ -> raise "boom" end)
    {id, agent} = start_agent()

    WardrikCore.ask(agent, "hi")
    assert_receive {:turn_stopped, %{agent_id: ^id, outcome: :crash}}

    assert %{state: :idle, in_flight: [], messages: [%{role: :user}]} = agent_state(agent)
  end

  test "a turn that fails leaves its message in history" do
    expect(ReqLLM, :stream_text, fn _, _, _ -> {:error, :rate_limited} end)
    {id, agent} = start_agent()

    WardrikCore.ask(agent, "hi")
    assert_receive {:turn_stopped, %{agent_id: ^id, outcome: :error}}

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
    assert_receive {:turn_stopped, %{agent_id: ^id, outcome: :ok}}

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

    ref = Process.monitor(agent)
    Process.exit(agent, :kill)
    assert_receive {:DOWN, ^ref, :process, _pid, :killed}

    {^id, agent} = start_agent(agent_id: id, capabilities: [Blocking])
    assert_receive {:tool_running, "call-a", tool}
    send(tool, :release)
    assert_receive {:turn_stopped, %{agent_id: ^id, outcome: :ok}}

    assert %{state: :idle, checkpoint: nil, in_flight: [], messages: messages} =
             agent_state(agent)

    assert [:user, :assistant, :tool, :assistant] = Enum.map(messages, & &1.role)
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
    assert_receive {:turn_stopped, %{agent_id: ^id, outcome: :park}}
    assert {:tool_calls, [{%{id: "1"}, {:park, :needs_approval}}]} = WardrikCore.parked(agent)

    assert :ok = WardrikCore.resume(agent, %{"nope" => :approve})
    assert_receive {:turn_stopped, %{agent_id: ^id, outcome: :park}}

    assert :ok = WardrikCore.resume(agent, %{"1" => :approve})

    assert_receive {:turn_stopped, %{agent_id: ^id, outcome: :ok}}

    assert %{state: :idle, parked: nil, in_flight: [], messages: messages} = agent_state(agent)
    assert [:user, :assistant, :tool, :assistant] = Enum.map(messages, & &1.role)
    assert nil == WardrikCore.parked(agent)
  end

  defp start_agent(opts \\ []) do
    {id, opts} =
      Keyword.pop_lazy(opts, :agent_id, fn -> "agent-#{System.unique_integer([:positive])}" end)

    {:ok, {agent, _}} =
      [agent_id: id, model: "anthropic:claude-haiku-4-5", capabilities: [Echo]]
      |> Keyword.merge(opts)
      |> WardrikCore.start_agent()

    {id, agent}
  end

  defp agent_state(agent), do: :sys.get_state(agent).user_state
end
