defmodule Throttlebeam.MixProject do
  use Mix.Project

  def project do
    [
      app: :throttlebeam,
      version: "0.2.0",
      elixir: "~> 1.15",
      description: "Keyed debounce, throttle and idempotency primitives on OTP.",
      source_url: "https://github.com/kiunye/ThrottleBeam",
      docs: [main: "readme", extras: ["README.md", "CHANGELOG.md"]],
      package: package(),
      deps: deps()
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/kiunye/ThrottleBeam"}
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {Throttlebeam.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:plug, "~> 1.14", optional: true},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end
end
