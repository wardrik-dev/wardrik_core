defmodule WardrikCore.Usage do
  @moduledoc "What a model call used. Its cost is in US dollars, and `nil` when the model has no price in dollars."

  defstruct input_tokens: 0, output_tokens: 0, usd: nil

  @type t() :: %__MODULE__{
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          usd: float() | nil
        }

  @doc false
  @spec from_req_llm(ReqLLM.Response.t(), LLMDB.Model.t() | String.t()) :: t()
  def from_req_llm(%ReqLLM.Response{} = response, model) do
    usage = ReqLLM.Response.usage(response) || %{}

    %__MODULE__{
      input_tokens: Map.get(usage, :input_tokens, 0),
      output_tokens: Map.get(usage, :output_tokens, 0),
      usd: dollars(usage, model)
    }
  end

  defp dollars(usage, model) do
    case ReqLLM.model(model) do
      {:ok, %LLMDB.Model{pricing: %{currency: "USD"}}} -> Map.get(usage, :total_cost)
      _not_in_dollars -> nil
    end
  end
end
