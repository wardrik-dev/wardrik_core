defmodule WardrikCore.Capability do
  @moduledoc """
  Extends what an agent can do. Capabilities are modules, so a context stays
  serializable; their tools are resolved at the start of every turn.
  """
  alias WardrikCore.Context

  @callback tools(Context.t()) :: [ReqLLM.Tool.t()]
end
