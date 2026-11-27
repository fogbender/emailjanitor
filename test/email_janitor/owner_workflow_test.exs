defmodule EmailJanitor.OwnerWorkflowTest do
  use ExUnit.Case, async: true
  alias EmailJanitor.Owner

  test "nested execution inherits its workflow's remaining dispatch budget" do
    assert {:error, :dispatch_window_exhausted} =
             Owner.workflow(fn -> Owner.run(fn -> Owner.dispatch_window() end) end, 5_000)
  end
end
