defmodule WardrikCore.Event do
  @moduledoc """
  An event is something that happened to an agent. Each one goes two places.

    * **Telemetry**, for instruments like metrics and traces. Its handlers run in the process that
      emits, and `:telemetry` detaches one that raises.
    * **The agent's `WardrikCore.Events` sink**, for clients that follow the agent, like a CLI, a
      TUI or a web page.

  An event has a telemetry name, like `[:wardrik_core, :turn, :stop]`, its measurements and its
  metadata. `WardrikCore.Telemetry` lists core's. A package emits its own the same way, and they
  reach the sink too:

      WardrikCore.Event.emit(context, [:my_package, :refused], %{}, %{call: call})
  """
  alias WardrikCore.Context

  @enforce_keys [:name, :time]
  defstruct [:name, :time, measurements: %{}, metadata: %{}]

  @type t() :: %__MODULE__{
          name: [atom()],
          time: DateTime.t(),
          measurements: map(),
          metadata: map()
        }

  @doc """
  Emits an event to telemetry and to a sink. Give it the context, which names the agent's sink, or a
  sink of your own as `{module, opts}`, or `nil` for telemetry alone.
  """
  @spec emit(Context.t() | Context.entry() | nil, [atom()], map(), map()) :: :ok
  def emit(source, name, measurements \\ %{}, metadata) do
    :telemetry.execute(name, measurements, metadata)

    source
    |> sink()
    |> deliver(%__MODULE__{
      name: name,
      time: DateTime.utc_now(),
      measurements: measurements,
      metadata: metadata
    })
  end

  defp sink(%Context{events: events}), do: events
  defp sink(events), do: events

  defp deliver(nil, _event), do: :ok

  defp deliver(sink, event) do
    {module, opts} = Context.entry(sink)
    module.handle_event(event, opts)
    :ok
  end
end
