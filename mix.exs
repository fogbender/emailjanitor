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
    [extra_applications: [:logger, :crypto, :inets, :ssl], mod: {EmailJanitor.Application, []}]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:mail, "~> 0.5.2"},
      {:gen_smtp, "== 1.3.0"},
      {:floki, "~> 0.38.0"},
      {:domainatrex, "~> 3.2"},
      {:ecto_sql, "~> 3.14"},
      {:postgrex, "~> 0.23.0"},
      {:req, "~> 0.7.0"},
      {:google_api_gmail, "~> 0.17.0"},
      {:google_api_pub_sub, "~> 0.42.0"},
      {:assent, "~> 0.4.0"},
      {:plug, "~> 1.20"},
      {:phoenix, "~> 1.8.17"},
      {:phoenix_html, "~> 4.4"},
      {:bandit, "~> 1.15"},
      {:stream_data, "~> 1.4", only: :test},
      {:req_llm, "~> 1.31.0"},
      {:ex_aws, "~> 2.8"},
      {:ex_aws_ses, "== 2.5.0"},
      {:ex_aws_s3, "== 2.6.1"},
      {:ex_aws_sqs, "== 3.5.0"},
      {:sweet_xml, "== 0.7.5"},
      {:tzdata, "== 1.2.2"},
      {:ex_aws_auth, "~> 1.6"}
    ]
  end
end
