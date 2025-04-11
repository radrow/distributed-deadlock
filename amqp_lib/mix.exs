defmodule AmqpLib.MixProject do
  use Mix.Project

  def project do
    [
      app: :amqp_lib,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      compilers: [:erlang] ++ Mix.compilers(),
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:amqp, "~> 4.0"},
      {:dialyxir, "~> 1.4.5", runtime: false},
      {:gen_state_machine, "~> 3.0.0"},
    ]
  end
end
