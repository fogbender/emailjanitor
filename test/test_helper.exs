ExUnit.start()

socket = System.fetch_env!("JANITOR_TEST_SOCKET")

{:ok, _} =
  EmailJanitor.TestRepo.start_link(
    socket_dir: socket,
    database: "emailjanitor_test",
    username: System.fetch_env!("USER"),
    port: 5432,
    pool: Ecto.Adapters.SQL.Sandbox,
    pool_size: 12,
    log: false
  )

for prefix <- [
      "ej_test_a",
      "ej_test_b",
      "ej_concurrency",
      "ej_recovery",
      "ej_policy_concurrency",
      "ej_digest_concurrency"
    ] do
  {:ok, scope} = EmailJanitor.Store.Scope.new(EmailJanitor.TestRepo, prefix)
  EmailJanitor.Store.install(scope)
  EmailJanitor.Mail.Store.install(scope)
  EmailJanitor.Digest.install(scope)
end

Ecto.Adapters.SQL.Sandbox.mode(EmailJanitor.TestRepo, :manual)
