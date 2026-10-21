defmodule WardrikCore.MixProject do
  use Mix.Project

  def project do
    [
      app: :wardrik_core,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit, :ekv],
        plt_core_path: "priv/plts",
        plt_local_path: "priv/plts"
      ],
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:req_llm, "~> 1.28"},
      {:durable_server, "~> 0.1.6"},
      {:telemetry, "~> 1.0"},
      # Pubsub, for broadcasting to subscribers.
      {:group, "~> 0.2"},
      {:ekv, "~> 0.4.8", optional: true},
      {:mimic, "~> 2.4", only: :test},
      # Anti-slop checks, as the reference's precommit runs them.
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.5", only: [:dev, :test], runtime: false},
      {:ex_crap, "~> 0.1.0", only: [:dev, :test], runtime: false},
      {:reach, "~> 2.8", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
