defmodule WardrikCore.Middleware do
  @moduledoc """
  Middleware extension point for WardrikCore

  Example uses:
    - Modifying system prompts.
    - Injecting telemetry.
    - Adding custom logging.
    - Enforcing compliance.

  Every unit of work passes through the chain, named by `context.step`:
  `:turn` once around the whole turn, `:generate` around each model call, and
  `{:tool_call, call}` around each tool call, inside that call's task. Steps
  nest in that order, so metadata set by an outer step (a parent span, say)
  reaches the steps inside it.
  """
  alias WardrikCore.Context
  @type context :: Context.t()
  @type result :: {:ok, context()} | {:error, term()} | {:park, term(), context()}
  @type next :: (context() -> result())

  @doc "Provided with the current context and a next function to call, returns a new context or an error."
  @callback call(context, next) :: result()
end
