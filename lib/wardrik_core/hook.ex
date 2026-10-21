defmodule WardrikCore.Hook do
  @moduledoc """
  Hooks behavior for all agent lifecycle events.
  """

  @type context :: WardrikCore.Context.t()
  @type decision ::
          {:continue, context()}
          | {:allow, context()}
          | {:ask, String.t(), context()}
          | {:deny, String.t(), context()}

  @doc "Fired when the agent initializes or recovers from a storage checkpoint"
  @callback on_init(context) :: decision

  @doc "Fired right before a turn is executed, allowing for last-minute modifications to the context."
  @callback before_turn(turn_number :: non_neg_integer(), context) :: decision

  @doc "Fired right before the prompt is sent to the LLM provider"
  @callback before_generation(context) :: decision

  @doc "Fired after the prompt is sent to the LLM provider and a response is received"
  @callback after_generation(response :: String.t(), context) :: decision

  @doc "Fired before any tool execution"
  @callback on_tool_call(tool_name :: String.t(), tool_args :: map(), context) :: decision

  @doc "Fired when an agent hits a boundary and parks (waiting for user input or other external event)"
  @callback on_park(reason :: term(), context) :: decision

  @doc "Fired when an agent resumes from a parked state, allowing for any necessary context adjustments."
  @callback on_resume(context) :: decision

  @doc "Fires when a turn loop finishes."
  @callback on_complete(context) :: decision

  @optional_callbacks [
    on_init: 1,
    before_turn: 2,
    before_generation: 1,
    after_generation: 2,
    on_tool_call: 3,
    on_park: 2,
    on_resume: 1,
    on_complete: 1
  ]
end
