defmodule Frostlake.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/Frostlake-DB/frostlake-elixir"

  def project do
    [
      app: :frostlake,
      version: @version,
      # Nothing newer than 1.14 is used anywhere in lib/; the driver is
      # developed and tested against 1.20 / OTP 29.
      elixir: "~> 1.14",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      # No dependencies at all, and not only at runtime: the transport is
      # :gen_tcp, the JSON layer is the driver's own, and the tests run on
      # ExUnit. `mix deps.get` has nothing to fetch.
      deps: [],
      name: "Frostlake",
      description:
        "Zero-dependency Elixir driver for the Frostlake SQL engine, speaking " <>
          "its HTTP protocol against a running DatabaseHttpServer.",
      package: package(),
      docs: docs()
    ]
  end

  def application do
    # Only the TLS path touches these, and it starts :ssl itself before opening a
    # socket; they are declared so an https:// DSN works in a release that was
    # never told about them.
    [extra_applications: [:ssl, :public_key]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url, "Frostlake" => "https://frostlake.dev"},
      files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      source_ref: "v#{@version}",
      extras: ["README.md", "CHANGELOG.md"]
    ]
  end
end
