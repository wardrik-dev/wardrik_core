defmodule WardrikCore.Telemetry do
  @moduledoc """
  Events an agent emits, each with `agent_id` in its metadata:

    * `[:wardrik_core, :agent, :start]` - `state`
    * `[:wardrik_core, :agent, :stop]` - `reason`
    * `[:wardrik_core, :message, :queued]` - `message`; measures `queued`
    * `[:wardrik_core, :turn, :start]` - `kind`, and the `metadata` given to `resume/3`
    * `[:wardrik_core, :turn, :stop]` - `kind`, `outcome`; measures `duration`
    * `[:wardrik_core, :turn, :checkpoint]` - measures `calls`
    * `[:wardrik_core, :turn, :dropped]`
    * `[:wardrik_core, :tool_call, :exit]` - `call`, `reason`
  """

  @spec emit([atom()], map(), map()) :: :ok
  def emit(event, measurements \\ %{}, metadata),
    do: :telemetry.execute([:wardrik_core | event], measurements, metadata)
end
