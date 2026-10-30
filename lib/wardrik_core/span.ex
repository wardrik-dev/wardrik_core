defmodule WardrikCore.Span do
  @moduledoc """
  A span in a turn's trace.

  A turn is the root span. Each of its steps runs in a child span.
  """

  @enforce_keys [:id, :trace]
  defstruct [:id, :trace, :parent]

  @type t() :: %__MODULE__{id: String.t(), trace: String.t(), parent: String.t() | nil}

  @doc "Starts a new trace."
  @spec root() :: t()
  def root, do: %__MODULE__{id: random(8), trace: random(16)}

  @doc """
  Starts a span beneath `parent`.

  With `:key`, the span's id is derived from the trace and the key, so it's the same each time.
  A tool call that runs again after a restart keeps its span this way.
  """
  @spec child(t(), keyword()) :: t()
  def child(%__MODULE__{} = parent, opts \\ []),
    do: %__MODULE__{id: id(parent, opts[:key]), trace: parent.trace, parent: parent.id}

  @doc """
  Returns the span as a W3C `traceparent` header, for OpenTelemetry.

      WardrikCore.Span.traceparent(span)
      #=> "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
  """
  @spec traceparent(t()) :: String.t()
  def traceparent(%__MODULE__{} = span), do: "00-#{span.trace}-#{span.id}-01"

  defp id(_parent, nil), do: random(8)

  defp id(parent, key) do
    :sha256
    |> :crypto.hash([parent.trace, key])
    |> binary_part(0, 8)
    |> Base.encode16(case: :lower)
  end

  defp random(bytes), do: bytes |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
end
