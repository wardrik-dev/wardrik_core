defmodule WardrikCore.Resume do
  @moduledoc """
  What a parked step sees when it runs again.

  Holds the `reason` it parked, the `input` passed to `WardrikCore.resume/3`, and that call's
  `metadata`.
  """

  @enforce_keys [:reason, :input]
  defstruct [:reason, :input, metadata: %{}]

  @type t() :: %__MODULE__{reason: term(), input: term(), metadata: map()}
end
