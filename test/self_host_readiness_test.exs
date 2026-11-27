defmodule EmailJanitor.SelfHostReadinessTest do
  use ExUnit.Case, async: false
  alias EmailJanitor.Google.OAuth
  alias EmailJanitor.SelfHost.{Adapters, Config, Runtime}

  @tag :tmp_dir
  test "missing or invalid Gmail topic prevents web and notification services from starting", %{
    tmp_dir: dir
  } do
    executable = Path.join(dir, "synthetic-helper")
    File.write!(executable, "#!/bin/sh\nexit 1\n")
    File.chmod!(executable, 0o700)

    {:ok, oauth} =
      OAuth.Config.new(
        "synthetic",
        "synthetic-secret",
        "https://janitor.example.com/auth/google/callback"
      )

    config = %Config{
      google_oauth: %{oauth | revocation_executable: executable},
      reply_parser_executable: executable,
      pubsub: %{
        "JANITOR_GOOGLE_TOKEN_FILE" => Path.join(dir, "unread-token"),
        "JANITOR_GOOGLE_SUBSCRIPTION" => "projects/janitor-project/subscriptions/changes",
        "JANITOR_GOOGLE_TOPIC" => "projects/janitor-project/topics/changes"
      },
      mail: %{
        "JANITOR_MAIL_SENDER" => "janitor@janitor.example.com",
        "JANITOR_MAIL_BUCKET" => "janitor-spool",
        "JANITOR_MAIL_QUEUE_URL" => "https://sqs.us-east-1.amazonaws.com/123456789012/janitor",
        "JANITOR_MAIL_TOPIC_ARN" => "arn:aws:sns:us-east-1:123456789012:janitor"
      }
    }

    assert Runtime.ready?(config)

    for topic <- [nil, "", "not-a-topic", "projects/janitor-project/topics/changes\n"] do
      bad = %{config | pubsub: Map.put(config.pubsub, "JANITOR_GOOGLE_TOPIC", topic)}
      assert {:error, :pubsub_not_configured} = Adapters.pubsub(bad)
      refute Runtime.ready?(bad)

      assert {:error, :incomplete_self_host_release} =
               EmailJanitor.SelfHost.Supervisor.start_link(bad)

      for process <- [
            EmailJanitor.SelfHost.Supervisor,
            EmailJanitor.SelfHost.Services,
            EmailJanitor.SelfHost.CleanupServer,
            EmailJanitor.SelfHost.Oban
          ],
          do: assert(Process.whereis(process) == nil)
    end

    refute File.exists?(Path.join(dir, "unread-token"))
  end
end
