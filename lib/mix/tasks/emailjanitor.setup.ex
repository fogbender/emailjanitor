defmodule Mix.Tasks.Emailjanitor.Setup do
  @moduledoc "Run local self-host setup without starting the Email Janitor application."
  @shortdoc "Prepare or inspect the AWS self-host configuration"
  use Mix.Task
  @requirements ["compile"]

  @impl true
  def run(args) do
    case EmailJanitor.Setup.CLI.main(args) do
      0 -> :ok
      _ -> Mix.raise("Email Janitor setup is incomplete; see the fixed status above.")
    end
  end
end
