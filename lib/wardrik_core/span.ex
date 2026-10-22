defmodule WardrikCore.Span do
  @moduledoc "A span of a turn's trace. Each step of a turn runs in a child of the turn's span."

  @enforce_keys [:id, :trace]
  defstruct [:id, :trace, :parent]

  @type t() :: %__MODULE__{id: String.t(), trace: String.t(), parent: String.t() | nil}

  @doc "Starts a new trace."
  @spec root() :: t()
  def root, do: %__MODULE__{id: random(8), trace: random(16)}

  @doc """
  Starts a span beneath `parent`. With a `:key`, it's the same span each time, like a tool call
  that runs again after a restart.
  """
  @spec child(t(), keyword()) :: t()
  def child(%__MODULE__{} = parent, opts \\ []),
    do: %__MODULE__{id: id(parent, opts[:key]), trace: parent.trace, parent: parent.id}

  @doc "The span as a W3C `traceparent` header, as OpenTelemetry reads it."
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
