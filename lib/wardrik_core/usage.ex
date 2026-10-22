defmodule WardrikCore.Usage do
  @moduledoc false

  @spec measurements(ReqLLM.Response.t(), LLMDB.Model.t() | String.t()) :: %{atom() => number()}
  def measurements(%ReqLLM.Response{} = response, model) do
    usage = ReqLLM.Response.usage(response) || %{}

    %{
      input_tokens: Map.get(usage, :input_tokens, 0),
      output_tokens: Map.get(usage, :output_tokens, 0)
    }
    |> put_dollars(dollars(usage, model))
  end

  defp put_dollars(measurements, nil), do: Map.put(measurements, :unpriced_calls, 1)
  defp put_dollars(measurements, usd), do: Map.put(measurements, :usd, usd)

  defp dollars(usage, model) do
    case ReqLLM.model(model) do
      {:ok, %LLMDB.Model{pricing: %{currency: "USD"}}} -> Map.get(usage, :total_cost)
      _not_in_dollars -> nil
    end
  end
end
