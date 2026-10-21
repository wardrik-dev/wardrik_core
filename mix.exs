defmodule WardrikCore.MixProject do
  use Mix.Project

  def project do
    [
      app: :wardrik_core,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {WardrikCore.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:uuid, "~> 1.1"},
      {:req_llm, "~> 1.28"},
      {:durable_server, "~> 0.1.6"},
      {:group, "~> 0.2"},
      {:ekv, "~> 0.4.8", optional: true},
      {:mimic, "~> 2.4"},
      {:jsv, "~> 0.26.1"},
      {:dialyxir, "~> 1.4", runtime: false},
      {:credo, "~> 1.7", runtime: false}
    ]
  end
end
