defmodule WardrikCore.Middleware do
  @moduledoc """
  Middleware extension point for WardrikCore

  Example uses:
    - Modifying system prompts.
    - Injecting telemetry.
    - Adding custom logging.
    - Enforcing compliance.

  """
  alias WardrikCore.Context
  @type context :: Context.t()
  @type result :: {:ok, context()} | {:error, term()} | {:park, term(), context()}
  @type next :: (context() -> result())

  @doc "Provided with the current context, a next function to call and its options, returns a new context or an error."
  @callback call(context, next, opts :: term()) :: result()
end
