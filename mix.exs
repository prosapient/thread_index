defmodule ThreadIndex.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/prosapient/thread_index"

  def project do
    [
      app: :thread_index,
      version: @version,
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      name: "ThreadIndex",
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:crypto]
    ]
  end

  defp description do
    "Encode and decode the Outlook Thread-Index header (MAPI PidTagConversationIndex) — " <>
      "both desktop Outlook and Exchange/OWA/Graph variants, with correct reply-date recovery."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib examples mix.exs README.md LICENSE CHANGELOG.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md"],
      source_ref: "v#{@version}"
    ]
  end

  defp deps do
    [
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end
end
