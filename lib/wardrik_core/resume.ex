defmodule WardrikCore.Resume do
  @moduledoc "A resume is what a parked step sees when it runs again: why it parked, the input it was given, and the caller's metadata."

  @enforce_keys [:reason, :input]
  defstruct [:reason, :input, metadata: %{}]

  @type t() :: %__MODULE__{reason: term(), input: term(), metadata: map()}
end
