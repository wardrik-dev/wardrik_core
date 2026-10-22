defmodule WardrikCore.ToolTest do
  use ExUnit.Case, async: true

  alias WardrikCore.Tool

  setup do
    %{
      tool: Tool.new!(name: "echo", description: "echo", run: fn _args, _context -> {:ok, ""} end)
    }
  end

  test "keeps private data under the key of the package that owns it", %{tool: tool} do
    tool = Tool.put_private(tool, MyPackage, %{gated: true})

    assert %{gated: true} = Tool.get_private(tool, MyPackage)
    assert :none = Tool.get_private(tool, OtherPackage, :none)
  end

  test "update_private/4 sets the default first, then updates", %{tool: tool} do
    tool = Tool.update_private(tool, MyPackage, 1, &(&1 + 1))
    assert 1 = Tool.get_private(tool, MyPackage)

    tool = Tool.update_private(tool, MyPackage, 1, &(&1 + 1))
    assert 2 = Tool.get_private(tool, MyPackage)
  end

  test "rejects options it doesn't know" do
    assert_raise KeyError, fn ->
      Tool.new!(name: "echo", description: "echo", run: fn _, _ -> {:ok, ""} end, meta: %{})
    end
  end
end
