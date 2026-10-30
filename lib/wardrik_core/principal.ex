defmodule WardrikCore.Principal do
  @moduledoc """
  Someone or something that can act, such as a person, a team or a service, as in IAM.

      %WardrikCore.Principal{id: "user:maria", attributes: %{org: "acme", team: "finance"}}

  Principals come from three places:

    * The agent's own, given to `WardrikCore.start_agent/2` as `:principal`.
    * A message's sender, given to `WardrikCore.ask/3`. The turn that answers acts for them.
    * Whoever resumes a parked turn.

  Core passes principals on but never reads their `attributes`. Those are yours, like IAM tags.
  Packages decide by them, such as a vault that keys secrets by `id`.
  """

  @enforce_keys [:id]
  defstruct [:id, attributes: %{}]

  @type t() :: %__MODULE__{id: String.t(), attributes: map()}
end
