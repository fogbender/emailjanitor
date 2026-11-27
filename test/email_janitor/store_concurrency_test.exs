defmodule EmailJanitor.StoreConcurrencyTest do
  use ExUnit.Case, async: false
  import EmailJanitor.Fixtures
  alias EmailJanitor.{Reviewer, Store, TestClassifier, TestRepo}
  alias EmailJanitor.Store.Scope

  test "independent database connections create exactly one durable intent" do
    # Unlike the transaction-sandbox tests this commits in a throwaway schema,
    # exercising the real unique constraint with separate concurrent connections.
    {:ok, scope} = Scope.new(TestRepo, "ej_concurrency")
    box = inbox()

    Ecto.Adapters.SQL.Sandbox.unboxed_run(TestRepo, fn ->
      {:ok, _} = Store.add_inbox(scope, box)
    end)

    {:ok, proposal} = Reviewer.review([message()], box, MapSet.new(), {TestClassifier, []}, "", 1)

    results =
      1..24
      |> Task.async_stream(
        fn _ ->
          Ecto.Adapters.SQL.Sandbox.unboxed_run(TestRepo, fn ->
            Store.intent(scope, box.id, proposal, "100")
          end)
        end,
        max_concurrency: 8,
        timeout: 15_000
      )
      |> Enum.map(fn {:ok, {:ok, result}} -> result end)

    assert Enum.count(results, fn {status, _} -> status == :created end) == 1
    assert Enum.count(results, fn {status, _} -> status == :existing end) == 23
    assert results |> Enum.map(fn {_, action} -> action.id end) |> Enum.uniq() |> length() == 1
  end
end
