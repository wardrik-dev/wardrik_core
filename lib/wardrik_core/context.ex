defmodule WardrikCore.Context do
  @moduledoc """
  Context passed through Wardrik
  """

  @type t() :: %__MODULE__{
          http_client: module(),
          llm_client: module(),
          capabilities: map(),
          middleware: map(),
          metadata: map()
        }

  defstruct [
    :http_client,
    :llm_client,
    capabilities: %{},
    middleware: %{},
    metadata: %{}
  ]
end
