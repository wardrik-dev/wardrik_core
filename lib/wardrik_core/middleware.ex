defmodule WardrikCore.Middleware do
  @moduledoc """
  Wraps every step of a turn: the turn itself, each model call, and each tool call.

      defmodule MyApp.NoShell do
        @behaviour WardrikCore.Middleware

        @impl true
        def call(%{step: {:tool_call, %{name: "shell"}}} = context, _next, _opts),
          do: {:ok, %{context | response: {:error, "No shell."}}}

        def call(context, next, _opts), do: next.(context)
      end

  Call `next` to carry on. To answer the step yourself, return `{:ok, context}`. Return
  `{:park, reason, context}` to wait for a person, or `{:error, reason}` to end the step.

  Reach for this when every call needs the same treatment: policy, tracing, retries, a system
  prompt.
  """
  alias WardrikCore.Context
  @type context :: Context.t()
  @type result :: {:ok, context()} | {:error, term()} | {:park, term(), context()}
  @type next :: (context() -> result())

  @doc "Takes the context, the `next` function and your options. Call `next` to carry on, or return early to stop."
  @callback call(context, next, opts :: term()) :: result()
end
