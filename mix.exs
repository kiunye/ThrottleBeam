defmodule Throttlebeam.MixProject do
  use Mix.Project

  def project do
    [
      app: :throttlebeam,
      version: "0.1.0",
      elixir: "~> 1.15",
      description: "Keyed debounce and throttle primitives on OTP, no external dependencies.",
      package: package(),
      deps: deps()
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/kiunye/throttlebeam"}
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Throttlebeam.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end
end
