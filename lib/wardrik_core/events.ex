defmodule WardrikCore.Events do
  @moduledoc """
  Where an agent's events go: a log, a broadcast, anything a client reads from.

      defmodule MyApp.Events do
        @behaviour WardrikCore.Events

        @impl true
        def handle_event(%WardrikCore.Event{} = event, _opts) do
          Phoenix.PubSub.broadcast(MyApp.PubSub, "agent:\#{event.metadata.agent_id}", event)
        end
      end

  Give it to an agent as `events: {MyApp.Events, opts}`. Core calls it with every
  `WardrikCore.Event`, in the process the event happens in. Keep it quick: store or send the event,
  and return.
  """

  @doc "Handles one event. The return value is ignored."
  @callback handle_event(WardrikCore.Event.t(), opts :: term()) :: any()
end
