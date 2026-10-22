defmodule WardrikCore.Capability do
  @moduledoc """
  Provides an agent's tools.
  """
  alias WardrikCore.Context

  @callback tools(Context.t(), opts :: term()) :: [WardrikCore.Tool.t()]
end
