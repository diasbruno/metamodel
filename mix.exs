defmodule Metamodel.MixProject do
  use Mix.Project

  @source_url "https://github.com/diasbruno/metamodel"
  @version "0.1.0"

  def project do
    [
      app: :metamodel,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "MetaDsl",
      description: description(),
      source_url: @source_url,
      homepage_url: @source_url,
      docs: docs(),
      package: package()
    ]
  end

  defp description do
    "A DSL for defining generator-agnostic meta-types and deriving new types from existing ones."
  end

  defp package do
    [
      licenses: ["Unlicense"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs README.md UNLICENSE)
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
      {:ex_doc, "~> 0.36", only: :dev, runtime: false}
    ]
  end

  defp docs do
    [
      main: "MetaDsl",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: ["README.md"],
      groups_for_modules: [
        "Core DSL": [MetaDsl],
        "Data Structures": [MetaDsl.MetaType, MetaDsl.Property, MetaDsl.Derivation],
        Generators: [MetaDsl.Generator, MetaDsl.Generators.Debug, MetaDsl.Generators.TypeScript]
      ]
    ]
  end
end
