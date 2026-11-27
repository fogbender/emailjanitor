defmodule EmailJanitor.ReconciliationTest do
  use ExUnit.Case, async: true
  alias EmailJanitor.Reconciliation
  alias EmailJanitor.Store.Action

  defp action(ids \\ ["one"]), do: %Action{history_id: "100", message_ids: ids}
  defp event(id, mid, kind), do: %{history_id: id, message_id: mid, event: kind}

  test "a removal then restoration never permits retry" do
    history = %{
      complete?: true,
      events: [event("101", "one", :inbox_removed), event("102", "one", :inbox_added)]
    }

    assert {:ok, %{removed_ids: ["one"], restored_ids: ["one"], retry_ids: []}} =
             Reconciliation.resolve(action(), history)
  end

  test "missing or expired history never permits a blind retry" do
    assert {:error, :incomplete_history} =
             Reconciliation.resolve(action(), %{complete?: false, events: []})

    assert {:error, :incomplete_history} = Reconciliation.resolve(action(), {:error, :expired})
  end

  test "complete history with no removal allows only a freshly rechecked retry" do
    assert {:ok, %{removed_ids: [], restored_ids: [], retry_ids: ["one"]}} =
             Reconciliation.resolve(action(), %{complete?: true, events: []})
  end

  test "partial batch success is resolved by exact IDs" do
    assert {:ok, %{removed_ids: ["one"], restored_ids: [], retry_ids: ["two"]}} =
             Reconciliation.resolve(action(["one", "two"]), %{
               complete?: true,
               events: [event("101", "one", :inbox_removed)]
             })
  end

  test "history ordering is numeric and ignores older and unrelated changes" do
    history = %{
      complete?: true,
      events: [
        event("102", "one", :inbox_added),
        event("99", "one", :inbox_removed),
        event("101", "other", :inbox_removed),
        event("101", "one", :inbox_removed)
      ]
    }

    assert {:ok, %{removed_ids: ["one"], restored_ids: ["one"], retry_ids: []}} =
             Reconciliation.resolve(action(), history)
  end

  test "malformed history cannot prove absence of a removal" do
    for bad <- [%{}, event("bad", "one", :inbox_removed), event("101", "one", :unknown)] do
      assert {:error, :incomplete_history} =
               Reconciliation.resolve(action(), %{complete?: true, events: [bad]})
    end
  end
end
