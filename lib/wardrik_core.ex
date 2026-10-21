defmodule WardrikCore do
  @moduledoc """
  Documentation for `WardrikCore`.
  """

  def start_agent(opts) do
    DurableServer.Supervisor.start_child(
      WardrikCore.DurableServer,
      {WardrikCore.Agent, opts}
    )
  end
end
