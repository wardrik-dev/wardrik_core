# Middleware

Middleware sees each turn, model call and tool call, as `context.step`. It calls `next` to carry
on, or answers the step itself. Here's one that refuses the shell:

```elixir
defmodule MyApp.NoShell do
  @behaviour WardrikCore.Middleware

  @impl true
  def call(%{step: {:tool_call, %{name: "shell"}}} = context, _next, _opts),
    do: {:ok, %{context | response: {:error, "No shell."}}}

  def call(context, next, _opts), do: next.(context)
end
```

A refusal is the call's answer. The model sees it as the call's error, and carries on.

Middleware can also park a call until a person answers. This one asks before any tool runs:

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

The turn waits until we resume it, with an answer for each call. Say who answered as the metadata,
and it's on the resumed turn's start event:

```elixir
{:tool_calls, calls} = WardrikCore.parked(agent)
WardrikCore.resume(agent, %{"call_1" => :approve}, %{by: maria})
```

Middleware can keep state with the agent, like a count or what it spent, with
`Context.put_private/3` under its own module's name. It's saved with the agent, so it survives
restarts. When middleware needs a model's judgement on a call, `WardrikCore.evaluate/4` asks an
evaluation model.

Reach for middleware when every call needs the same treatment: policy, tracing, retries, a system
prompt. Like capabilities, it takes options as `{MyApp.Approve, opts}`.
