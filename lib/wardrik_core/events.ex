defmodule WardrikCore.Events do
  @moduledoc """
  An events sink is where an agent's events go: a log, a broadcast, anything a client reads from.

  Give an agent one as `events: {MyApp.Events, opts}`. Core hands it every `WardrikCore.Event` as it
  happens, in the process it happens in, so a sink must be quick. Store or send the event, and
  return.

  Reach for this when clients need to follow what an agent does, like a CLI, a TUI or a web page.
  """

  @callback handle_event(WardrikCore.Event.t(), opts :: term()) :: any()
end
