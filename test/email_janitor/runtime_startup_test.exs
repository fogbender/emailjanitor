defmodule EmailJanitor.RuntimeStartupTest do
  use ExUnit.Case, async: true

  test "a clean BEAM starts the engine's production Httpc and TLS dependencies" do
    # A separate Elixir VM has no Mix/Hex/test helper that could prestart :inets.
    script = """
    nil = Process.whereis(:httpc_manager)
    {:ok, applications} = Application.ensure_all_started(:email_janitor)
    true = :inets in applications
    true = :ssl in applications
    true = is_pid(Process.whereis(:httpc_manager))
    IO.puts("engine-http-runtime-ready")
    """

    paths = Path.join([Mix.Project.build_path(), "lib", "*", "ebin"])

    {output, status} =
      System.cmd(System.find_executable("elixir"), ["-pa", paths, "-e", script],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "engine-http-runtime-ready"
  end
end
