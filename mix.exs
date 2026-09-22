defmodule Errata.MixProject do
  use Mix.Project

  @version "1.9.3"
  @source_url "https://github.com/jvoegele/errata"

  def project do
    [
      app: :errata,
      version: @version,
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      consolidate_protocols: Mix.env() != :test,
      start_permanent: Mix.env() == :prod,
      deps: deps(),

      # Dialyzer: keep PLTs in a stable, cacheable location for CI
      dialyzer: [
        plt_local_path: "priv/plts",
        plt_core_path: "priv/plts"
      ],

      # Hex
      description: "Elixir library for structured error handling",
      package: package(),

      # Docs
      name: "Errata",
      source_url: @source_url,
      docs: docs()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:jason, ">= 1.3.0", optional: true},
      {:telemetry, "~> 1.0"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      name: :errata,
      # `guides` ships because the README links into it a dozen times; without it those
      # links are dead for anyone reading the package from Hex rather than GitHub.
      # `usage-rules.md` is agent-facing guidance, consumed by `usage_rules`
      # (https://hex.pm/packages/usage_rules); it must be listed or `mix usage_rules.sync`
      # finds nothing.
      files: [
        "lib",
        "guides",
        "usage-rules.md",
        "mix.exs",
        "README.md",
        "LICENSE",
        "CHANGELOG.md"
      ],
      maintainers: ["Jason Voegele"],
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url}
    ]
  end

  @guides [
    "guides/getting-started.md",
    "guides/handling-errors.md",
    "guides/wrapping-errors.md",
    "guides/boundaries.md",
    "guides/observability.md",
    "guides/testing.md",
    "guides/design.md",
    "guides/ai-coding-agents.md"
  ]

  defp docs do
    [
      # Getting started is the landing page, so a new reader arrives at installation and a first
      # error type rather than at the reference. The README remains the `Errata` moduledoc (see
      # `lib/errata.ex`), which is where the conceptual overview lives, so nothing duplicates.
      # The README's own Installation section sits outside the moduledoc markers on purpose:
      # setup belongs to this landing page, not to the API reference for the module.
      main: "getting-started",
      extras: [
        # Guides, ordered as a learning path.
        "guides/getting-started.md": [title: "Getting started"],
        "guides/handling-errors.md": [title: "Handling errors"],
        "guides/wrapping-errors.md": [title: "Wrapping and composing errors"],
        "guides/boundaries.md": [title: "Errors at a boundary"],
        "guides/observability.md": [title: "Reporting errors"],
        "guides/testing.md": [title: "Testing with Errata"],
        "guides/design.md": [title: "Design notes"],
        "guides/ai-coding-agents.md": [title: "Errata and AI coding agents"],
        # Agent-facing, but published here too: the agents guide links to it, and a reader
        # browsing HexDocs should be able to see what their agent is being told.
        "usage-rules.md": [title: "Usage rules"],
        "CHANGELOG.md": [title: "Changelog"],
        LICENSE: [title: "License"]
      ],
      groups_for_extras: [
        Guides: @guides,
        Reference: ["usage-rules.md"]
      ],
      filter_modules: fn _module, meta ->
        # This allows us to tag modules as internal and exclude them from the API docs as follows:
        #         #   @moduledoc internal: true
        not Map.get(meta, :internal, false)
      end
    ]
  end
end
