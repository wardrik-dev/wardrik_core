defmodule WardrikCore.Middleware do
  @moduledoc """
  Wraps every step of a turn: the turn itself, each model call, and each tool call.

  Use it when every call needs the same treatment, such as policy, tracing, retries or a system
  prompt.

      defmodule MyApp.NoShell do
        @behaviour WardrikCore.Middleware

        @impl true
        def call(%{step: {:tool_call, %{name: "shell"}}} = context, _next, _opts),
          do: {:ok, %{context | response: {:error, "No shell."}}}

        def call(context, next, _opts), do: next.(context)
      end

  Give it to an agent as `middleware: [MyApp.NoShell]` or `middleware: [{MyApp.NoShell, opts}]`.
  The first in the list runs outermost.

  ## Return values

    * `next.(context)` - carries on.
    * `{:ok, context}` - answers the step yourself, with `context.response` as the answer.
    * `{:park, reason, context}` - waits for a person. See `WardrikCore.resume/3`.
    * `{:error, reason}` - ends the step.
  """
  alias WardrikCore.Context
  @type context :: Context.t()
  @type result :: {:ok, context()} | {:error, term()} | {:park, term(), context()}
  @type next :: (context() -> result())

  @doc "Handles one step. Call `next` to carry on, or return a result to stop."
  @callback call(context, next, opts :: term()) :: result()
end
