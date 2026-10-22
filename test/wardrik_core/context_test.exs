defmodule WardrikCore.ContextTest do
  use ExUnit.Case, async: true

  alias WardrikCore.Context

  defmodule Tag do
    @behaviour WardrikCore.Middleware

    @impl true
    def call(context, next) do
      context = update_in(context.metadata[:trail], &[:tag | &1 || []])
      next.(context)
    end
  end

  defmodule Halt do
    @behaviour WardrikCore.Middleware

    @impl true
    def call(context, _next), do: {:park, :needs_approval, context}
  end

  test "new/1 rejects options it doesn't know" do
    assert_raise KeyError, fn -> Context.new(not_a_field: true) end
  end

  describe "run/2" do
    test "runs middleware outermost first, then the function" do
      context = Context.new(middleware: [Tag, Tag])

      assert {:ok, %Context{metadata: %{trail: [:done, :tag, :tag]}}} =
               Context.run(context, fn ctx ->
                 {:ok, update_in(ctx.metadata[:trail], &[:done | &1])}
               end)
    end

    test "a middleware can stop the pipeline without calling next" do
      context = Context.new(middleware: [Halt])

      assert {:park, :needs_approval, ^context} =
               Context.run(context, fn _ -> flunk("next should not run") end)
    end
  end

  test "run/3 keeps chunk handlers to the step that added them" do
    handler = fn _chunk -> :ok end

    assert {:ok, %Context{on_chunk: [], step: nil}} =
             Context.run(Context.new([]), :generate, fn context ->
               {:ok, %{context | on_chunk: [handler | context.on_chunk]}}
             end)
  end
end
