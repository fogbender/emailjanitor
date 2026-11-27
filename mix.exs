defmodule EmailJanitor.MixProject do
  use Mix.Project

  def project do
    [
      app: :email_janitor,
      version: "0.1.0-dev",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Single-user email cleanup engine and self-hosted service",
      package: [
        licenses: ["MIT"],
        links: %{"GitHub" => "https://github.com/fogbender/emailjanitor"}
      ]
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:mail, "~> 0.5.2"},
      {:floki, "~> 0.38.0"},
      {:domainatrex, "~> 3.2"},
      {:ecto_sql, "~> 3.14"},
      {:postgrex, "~> 0.23.0"},
      {:req, "~> 0.7.0"},
      {:req_llm, "~> 1.31.0"},
      {:ex_aws, "~> 2.8"},
      {:ex_aws_auth, "~> 1.6"},
      {:plug, "~> 1.20", only: :test},
      {:stream_data, "~> 1.4", only: :test}
    ]
  end
end
