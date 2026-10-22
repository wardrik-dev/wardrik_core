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

  @doc "Takes the context, the `next` function and your options. Call `next` to carry on, or return early to stop."
  @callback call(context, next, opts :: term()) :: result()
end
