# Middleware

Middleware wraps each turn, model call and tool call. It reads the step from `context.step`, then
calls `next` to carry on or answers the step itself. This one refuses the shell:

```elixir
defmodule MyApp.NoShell do
  @behaviour WardrikCore.Middleware

  @impl true
  def call(%{step: {:tool_call, %{name: "shell"}}} = context, _next, _opts),
    do: {:ok, %{context | response: {:error, "No shell."}}}

  def call(context, next, _opts), do: next.(context)
end
```

The refusal becomes the call's answer. The model sees it as an error, and carries on.

Use middleware when every call needs the same treatment: policy, tracing, retries, a system prompt.
Like capabilities, it takes options as `{MyApp.NoShell, opts}`.

## Waiting for a person

Middleware can park a call until a person answers. This one asks before any tool runs:

```elixir
defmodule MyApp.Approve do
  @behaviour WardrikCore.Middleware

  @impl true
  def call(%{step: {:tool_call, call}} = context, next, _opts) do
    case answer(context, call) do
      :approve -> next.(context)
      {:deny, reason} -> {:ok, %{context | response: {:error, reason}}}
      nil -> {:park, :approval, context}
    end
  end

  def call(context, next, _opts), do: next.(context)

  defp answer(%{resume: %{input: answers}}, call), do: Map.get(answers, call.id)
  defp answer(_context, _call), do: nil
end
```

The turn waits until you resume it with an answer for each call. Pass who answered as metadata. It
appears on the resumed turn's start event:

```elixir
{:tool_calls, calls} = WardrikCore.parked(agent)
WardrikCore.resume(agent, %{"call_1" => :approve}, %{by: maria})
```

## Private state

Middleware can keep state with the agent, such as a count or what it spent. Store it with
`WardrikCore.Context.put_private/3`, under your own module as the key. It's saved with the agent,
so it survives restarts.

## Asking a model

When middleware needs a model's judgement on a call, `WardrikCore.evaluate/4` asks an evaluation
model. `WardrikCore.generate/1` calls the agent's own model.
