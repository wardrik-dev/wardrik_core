defmodule WardrikCore.Retry do
  @moduledoc """
  How a turn tries again what failed in passing, so every model call and every tool call that may
  run twice is fault tolerant without a line of its own.

  It waits a random while before each try: up to a second, then two, then four, and so on, never
  more than `:max_wait`. An agent's `:retries` set `:attempts`, the tries after the first, 6 unless
  set, `:max_wait`, in milliseconds, a minute unless set, and `:on_exhausted`, what a model call
  does once they're spent: `:ask` a person to try again, unless set, or `:fail`.

  A model call is tried again when it failed with an exception, as a timeout, a dropped stream, a
  rate limit or a 5xx do, but not on a 4xx other than 408, 425 and 429, nor when a middleware
  refused it. A tool call is tried again when its tool says it's `idempotent` or `read_only` and it
  raised, crashed or ran out of time: a tool answers `{:error, reason}` for what trying again won't
  change, and lets what might crash.
  """

  defmodule Exhausted do
    @moduledoc """
    What a turn waits on once a model call's tries are spent: a person to say whether to try again.
    Resume it with `%{"model" => :approve}` to try again with a fresh set, or `{:deny, reason}` to
    fail the turn.
    """

    @enforce_keys [:message]
    defstruct [:message, interrupt: "model_approval", labels: []]

    @type t() :: %__MODULE__{message: String.t(), interrupt: String.t(), labels: [String.t()]}
  end

  @attempts 6
  @max_wait :timer.minutes(1)
  @hopeless [400, 401, 402, 403, 404, 405, 406, 409, 410, 411, 412, 413, 414, 415, 422]

  @typedoc "An agent's retries: `:attempts`, `:max_wait` in milliseconds, and `:on_exhausted`."
  @type t() :: keyword()

  @doc """
  Runs `fun`, and runs it again while `transient` says what it answered failed in passing, as
  `announce` hears before each wait. Returns `{:ok, answer}`, or `{:spent, answer, tries}` once the
  tries ran out.
  """
  @spec run(t(), (-> answer), (answer -> term() | nil), (map() -> any())) ::
          {:ok, answer} | {:spent, answer, pos_integer()}
        when answer: term()
  def run(retries, fun, transient, announce),
    do: tried(settings(retries), fun, transient, announce, 1)

  @doc "Says how many tries `retries` allow after the first."
  @spec attempts(t()) :: non_neg_integer()
  def attempts(retries), do: Keyword.get(retries, :attempts, @attempts)

  @doc "Says what a model call does once `retries` are spent: `:ask` or `:fail`."
  @spec on_exhausted(t()) :: :ask | :fail
  def on_exhausted(retries), do: Keyword.get(retries, :on_exhausted, :ask)

  @doc "Says whether a model call that failed with `reason` may succeed if tried again."
  @spec transient?(term()) :: boolean()
  def transient?(%{status: status}) when status in @hopeless, do: false
  def transient?(%{__exception__: true}), do: true
  def transient?({:exit, _reason}), do: true
  def transient?(:timeout), do: true
  def transient?(_reason), do: false

  defp settings(retries),
    do: %{attempts: attempts(retries), max_wait: Keyword.get(retries, :max_wait, @max_wait)}

  defp tried(settings, fun, transient, announce, attempt) do
    answer = fun.()

    case transient.(answer) do
      nil -> {:ok, answer}
      _reason when attempt > settings.attempts -> {:spent, answer, attempt}
      reason -> again(settings, fun, transient, announce, attempt, reason)
    end
  end

  defp again(settings, fun, transient, announce, attempt, reason) do
    wait = wait(attempt, settings.max_wait)
    announce.(%{attempt: attempt, attempts: settings.attempts, wait_ms: wait, reason: reason})
    Process.sleep(wait)
    tried(settings, fun, transient, announce, attempt + 1)
  end

  defp wait(_attempt, 0), do: 0

  defp wait(attempt, max_wait),
    do: :rand.uniform(min(:timer.seconds(2 ** (attempt - 1)), max_wait))
end
