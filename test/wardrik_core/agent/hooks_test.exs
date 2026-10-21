defmodule WardrikCore.Agent.HooksTest do
  use ExUnit.Case, async: true

  alias WardrikCore.Hook, as: Hooks

  defmodule TestHookMod do
    @behaviour Hooks

    @impl Hooks
    def on_init(context), do: {:continue, context}

    @impl Hooks
    def before_turn(_turn_number, context), do: {:continue, context}

    @impl Hooks
    def before_generation(context), do: {:continue, context}

    @impl Hooks
    def after_generation(_response, context), do: {:continue, context}

    @impl Hooks
    def on_tool_call(_tool_name, _tool_args, context), do: {:continue, context}

    @impl Hooks
    def on_park(_reason, context), do: {:continue, context}

    @impl Hooks
    def on_resume(context), do: {:continue, context}

    @impl Hooks
    def on_complete(context), do: {:continue, context}
  end

  test "TestHookMod implements all required callbacks" do
    context = %WardrikCore.Context{}
    assert {:continue, ^context} = TestHookMod.on_init(context)
    assert {:continue, ^context} = TestHookMod.before_turn(1, context)
    assert {:continue, ^context} = TestHookMod.before_generation(context)
    assert {:continue, ^context} = TestHookMod.after_generation("response", context)
    assert {:continue, ^context} = TestHookMod.on_tool_call("tool", %{}, context)
    assert {:continue, ^context} = TestHookMod.on_park(:reason, context)
    assert {:continue, ^context} = TestHookMod.on_resume(context)
    assert {:continue, ^context} = TestHookMod.on_complete(context)
  end
end
