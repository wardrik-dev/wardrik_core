defmodule WardrikCoreTest do
  use ExUnit.Case, async: true
  use Mimic

  doctest WardrikCore

  describe "evaluate/4" do
    test "gives each answer under its question's name, and what the call used" do
      questions = %{"urgent" => %{type: :boolean, instructions: "Is this urgent?"}}

      expect(ReqLLM, :evaluate, fn "anthropic:claude-haiku-4-5",
                                   "The site is down.",
                                   ^questions ->
        {:ok,
         %ReqLLM.Response{
           id: "eval",
           model: "claude-haiku-4-5",
           context: nil,
           message: nil,
           object: %{"urgent" => %{"probability" => 0.9}},
           usage: %{input_tokens: 12, output_tokens: 1, total_cost: 0.001}
         }}
      end)

      assert {:ok, %{"urgent" => %{"probability" => 0.9}},
              %WardrikCore.Usage{input_tokens: 12, output_tokens: 1, usd: 0.001}} =
               WardrikCore.evaluate(
                 WardrikCore.Context.new([]),
                 "anthropic:claude-haiku-4-5",
                 "The site is down.",
                 questions
               )
    end

    test "passes on why the model couldn't answer" do
      expect(ReqLLM, :evaluate, fn _model, _state, _questions -> {:error, :timeout} end)

      assert {:error, :timeout} =
               WardrikCore.evaluate(WardrikCore.Context.new([]), "typesafe:jev-latest", "x", %{})
    end
  end
end
