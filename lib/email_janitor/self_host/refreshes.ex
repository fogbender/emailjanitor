defmodule EmailJanitor.SelfHost.RefreshAttempt do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, Ecto.UUID, autogenerate: false}
  @derive {Inspect, only: [:id, :inbox_id, :state]}
  schema "self_host_refreshes" do
    field(:inbox_id, :string)
    field(:source_version, :integer)
    field(:state, Ecto.Enum, values: [:wire, :ambiguous, :quarantined])
    field(:owner_token, Ecto.UUID)
    field(:owner_runtime, :string)
    field(:owner_host, :string)
    field(:owner_boot, :string)
    field(:owner_os_pid, :string)
    field(:owner_os_start, :string)
    field(:owner_beam_pid, :binary, redact: true)
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule EmailJanitor.SelfHost.Refreshes do
  @moduledoc "Pre-wire refresh ownership; retirement cannot outrun a late or lost rotation."
  import Ecto.Query
  alias EmailJanitor.{Owner, SelfHost}
  alias EmailJanitor.SelfHost.{Grants, RefreshAttempt, Store}

  def begin(ref, before) do
    scope = SelfHost.scope()
    # A caller's outer transaction must never roll back the pre-wire evidence.
    if scope.repo.in_transaction?() do
      {:error, :refresh_unavailable}
    else
      Store.transaction(fn scope ->
        Store.lock_mailbox(scope, before.id)

        with {:ok, current, _} <- Store.fetch_binding(ref),
             true <- current.token_version == before.token_version do
          running =
            scope.repo.aggregate(
              from(r in RefreshAttempt,
                where: r.inbox_id == ^before.id and r.state in [:wire, :ambiguous]
              ),
              :count,
              prefix: scope.prefix,
              log: false
            )

          if running >= 8, do: scope.repo.rollback(:refresh_unavailable)
          Grants.retain_cipher!(scope, current.id, current.token_ciphertext)

          fields =
            Map.merge(Owner.capture(), %{
              id: Ecto.UUID.generate(),
              inbox_id: current.id,
              source_version: current.token_version,
              state: :wire
            })

          scope.repo.insert!(struct!(RefreshAttempt, fields), prefix: scope.prefix, log: false)
        else
          _ -> scope.repo.rollback(:credentials_changed)
        end
      end)
    end
  end

  @doc false
  def complete!(scope, attempt) do
    current = owned!(scope, attempt)
    scope.repo.delete!(current, prefix: scope.prefix, log: false)
    :ok
  end

  def ambiguous(attempt) do
    Store.transaction(fn scope ->
      Store.lock_mailbox(scope, attempt.inbox_id)
      current = owned!(scope, attempt)

      scope.repo.update!(Ecto.Changeset.change(current, state: :ambiguous),
        prefix: scope.prefix,
        log: false
      )

      :ok
    end)
  end

  @doc false
  def ready?(scope, inbox) do
    not scope.repo.exists?(
      from(r in RefreshAttempt,
        where: r.inbox_id == ^inbox and r.state in [:wire, :ambiguous]
      ),
      prefix: scope.prefix,
      log: false
    )
  end

  @doc false
  def uncertain?(scope, inbox),
    do:
      scope.repo.exists?(
        from(r in RefreshAttempt,
          where: r.inbox_id == ^inbox
        ),
        prefix: scope.prefix,
        log: false
      )

  @doc false
  # A successful project-wide provider revocation, or the explicit local ALL
  # access-removed attestation, is needed to resolve a response lost after wire.
  def confirmed_project_removed!(scope, inbox) do
    unless ready?(scope, inbox), do: scope.repo.rollback(:refresh_pending)

    scope.repo.delete_all(from(r in RefreshAttempt, where: r.inbox_id == ^inbox),
      prefix: scope.prefix,
      log: false
    )

    :ok
  end

  def quarantine_one do
    scope = SelfHost.scope()

    rows =
      scope.repo.all(
        from(r in RefreshAttempt,
          where: r.state in [:wire, :ambiguous],
          order_by: [asc: r.inserted_at, asc: r.id],
          limit: 100
        ),
        prefix: scope.prefix,
        log: false
      )

    case Enum.find(rows, &(Owner.proof(&1) == :dead)) do
      nil ->
        :idle

      row ->
        # Assent's fixed SDK bounds are connect10s + receive15s. A monotonic
        # physical wait after confirmed owner death covers its last possible
        # request even when the wall clock jumps or the caller loses the response.
        Process.sleep(30_000)

        case Store.transaction(fn scope ->
               Store.lock_mailbox(scope, row.inbox_id)
               current = scope.repo.get(RefreshAttempt, row.id, prefix: scope.prefix, log: false)

               if current && current.owner_token == row.owner_token &&
                    current.state in [:wire, :ambiguous] && Owner.proof(current) == :dead do
                 scope.repo.update!(Ecto.Changeset.change(current, state: :quarantined),
                   prefix: scope.prefix,
                   log: false
                 )

                 :quarantined
               else
                 :idle
               end
             end) do
          {:ok, result} -> result
          _ -> :unavailable
        end
    end
  end

  defp owned!(scope, attempt) do
    current = scope.repo.get!(RefreshAttempt, attempt.id, prefix: scope.prefix, log: false)

    unless current.owner_token == attempt.owner_token && Owner.owns?(current) &&
             current.state == :wire,
           do: scope.repo.rollback(:refresh_changed)

    current
  end
end
