defmodule EmailJanitor.Setup.CLI do
  @moduledoc "Minimal operator CLI. Output contains fixed statuses and public metadata, never secret values."
  alias EmailJanitor.Setup

  @help """
  Email Janitor AWS setup (workers remain disabled)
    init --directory PATH --owner EMAIL --public-url URL
    doctor [--settings PATH]
    wif-config --provider RESOURCE --service-account EMAIL --output PATH

  init creates private keys and metadata settings without overwriting existing files.
  doctor checks local configuration/database only; cloud readiness and consent require
  the manual steps in docs/setup.md. wif-config runs official gcloud with AWS IMDSv2.
  """

  def main_json(json) do
    with {:ok, args} when is_list(args) <- Jason.decode(json),
         true <- length(args) <= 20 and Enum.all?(args, &is_binary/1) do
      main(args)
    else
      _ -> print_error(:invalid_arguments)
    end
  end

  def main(args) do
    case run(args) do
      {:ok, value} ->
        IO.puts(Jason.encode!(value, pretty: true))
        0

      {:not_ready, value} ->
        IO.puts(Jason.encode!(value, pretty: true))
        2

      :help ->
        IO.puts(@help)
        0

      {:error, reason} ->
        print_error(reason)
    end
  end

  def run([]), do: :help
  def run(["--help"]), do: :help

  def run(["init" | args]) do
    with {:ok, opts} <- parse(args, directory: :string, owner: :string, public_url: :string),
         true <- Enum.all?([:directory, :owner, :public_url], &is_binary(opts[&1])) do
      Setup.init(opts[:directory], opts[:owner], opts[:public_url])
    else
      _ -> {:error, :invalid_arguments}
    end
  end

  def run(["doctor" | args]) do
    with {:ok, opts} <- parse(args, settings: :string),
         {:ok, env} <-
           if(opts[:settings],
             do: Setup.load_settings(opts[:settings]),
             else: {:ok, System.get_env()}
           ),
         {:ok, result} <- Setup.doctor(env) do
      if result.local_ready, do: {:ok, result}, else: {:not_ready, result}
    end
  end

  def run(["wif-config" | args]) do
    with {:ok, opts} <- parse(args, provider: :string, service_account: :string, output: :string),
         true <- Enum.all?([:provider, :service_account, :output], &is_binary(opts[&1])) do
      Setup.wif_config(opts[:provider], opts[:service_account], opts[:output])
    else
      _ -> {:error, :invalid_arguments}
    end
  end

  def run(_), do: {:error, :invalid_arguments}

  defp parse(args, switches) do
    case OptionParser.parse(args, strict: switches) do
      {opts, [], []} ->
        if length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))),
          do: {:ok, opts},
          else: {:error, :invalid_arguments}

      _ ->
        {:error, :invalid_arguments}
    end
  end

  defp print_error(reason) do
    IO.puts(:stderr, "Email Janitor setup: " <> Atom.to_string(reason))
    1
  end
end
