defmodule Amps.MixProject do

  use Mix.Project

  def project do
    [
      app: :amps_monngodb,
      version: "0.1.0",
      elixir: "~> 1.12",
      aliases: aliases(),
      deps: deps()
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      extra_applications: []
    ]
  end

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:mongodb_driver, "~> 0.7"},
      {:uuid, "~> 2.0", hex: :uuid_erl},
      {:poison, "~> 3.1"},
    {:jason, "~> 1.2"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get"]
    ]
  end
end
