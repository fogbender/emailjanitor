defmodule EmailJanitor.Preferences.Lock do
  @moduledoc false
  def acquire(scope, mode) when mode in [:shared, :exclusive] do
    function =
      if mode == :shared, do: "pg_advisory_xact_lock_shared", else: "pg_advisory_xact_lock"

    Ecto.Adapters.SQL.query!(
      scope.repo,
      "SELECT #{function}(hashtextextended($1, 0))",
      ["emailjanitor_preferences:" <> scope.prefix],
      log: false
    )

    :ok
  end
end
