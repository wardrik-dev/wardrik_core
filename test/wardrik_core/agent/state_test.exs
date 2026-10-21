defmodule WardrikCore.Agent.StateTest do
  use ExUnit.Case, async: true

  alias WardrikCore.Agent.State

  describe "new/1" do
    test "creates a new state struct with the given options" do
      opts = [uuid: "1234", agent_id: "agent_1", model: "moonshotai:kimi-k3", state: :idle]
      state = State.new(opts)

      assert %State{} = state
      assert state.uuid == "1234"
      assert state.agent_id == "agent_1"
      assert %LLMDB.Model{} = state.model
      assert state.state == :idle
    end

    test "raises an error if the model is not valid" do
      opts = [uuid: "1234", agent_id: "agent_1", model: "invalid-model", state: :idle]

      assert_raise ArgumentError, fn ->
        State.new(opts)
      end
    end
  end
end
