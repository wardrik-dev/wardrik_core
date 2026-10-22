defmodule WardrikCore.Authorization do
  @moduledoc """
  An authorization is a sign-in a person must finish before a call can run.

  A call parks on one when `WardrikCore.Credentials.fetch/2` can't give it a credential yet. Show
  the person its `url`. Once they've signed in, resume the turn, and the call runs again.
  """

  @enforce_keys [:url, :credential]
  defstruct [:url, :credential, :principal]

  @type t() :: %__MODULE__{
          url: String.t(),
          credential: String.t(),
          principal: WardrikCore.Principal.t() | nil
        }
end
