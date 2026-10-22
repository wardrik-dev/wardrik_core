defmodule WardrikCore.Principal do
  @moduledoc """
  A principal is someone or something that can act, like a person, a team or a service, as in IAM.

      %WardrikCore.Principal{id: "user:maria", attributes: %{org: "acme", team: "finance"}}

  An agent has a principal of its own, given to `WardrikCore.start_agent/2`. A message can come
  from another, given to `WardrikCore.ask/3`, and the turn that answers it acts on their behalf.
  A person who resumes a parked turn is one too.

  Core keeps principals and passes them on. It never reads their `attributes`, which are yours, like
  IAM's tags. Packages decide by them, like a vault that keys secrets by `id`.
  """

  @enforce_keys [:id]
  defstruct [:id, attributes: %{}]

  @type t() :: %__MODULE__{id: String.t(), attributes: map()}
end
