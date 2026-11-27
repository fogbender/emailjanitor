defmodule EmailJanitor.Mail.Spool do
  @moduledoc """
  Temporary S3 input with a one-hour processing TTL that failures never extend.
  Store only receipt references/outcomes, and acknowledge SQS after accept/2 is
  durable. The host authenticates SES receipt + conversation before selecting the
  Scope/inbox. MIME From alone never authorizes an instruction.

  Handlers may be retried after a crash: they MUST independently deduplicate each
  mutation, preference edit and reply using the supplied stable SES receipt ID.
  Run sweep/2 at least minutely, including when the parser/authorizer is failing.
  S3 lifecycle is only a delayed fallback while this host/AWS is unavailable.
  """
  import Ecto.Query
  alias EmailJanitor.Owner
  alias EmailJanitor.Mail.{Config, Incoming, Receipt, SDK}
  alias EmailJanitor.Store.{Mailbox, Scope}

  def get(%Scope{} = scope, id), do: scope.repo.get(Incoming, id, prefix: scope.prefix)

  def accept(%Scope{} = scope, inbox_id, %Receipt{} = receipt) do
    with %Mailbox{} <- scope.repo.get(Mailbox, inbox_id, prefix: scope.prefix) do
      row = %Incoming{
        id: receipt.id,
        inbox_id: inbox_id,
        object_key: receipt.key,
        envelope_from: receipt.envelope_from,
        recipients: receipt.recipients,
        verdicts: receipt.verdicts,
        expires_at: DateTime.add(receipt.received_at, 3600)
      }

      scope.repo.insert!(row, prefix: scope.prefix, on_conflict: :nothing, conflict_target: [:id])

      case scope.repo.get!(Incoming, receipt.id, prefix: scope.prefix) do
        %Incoming{inbox_id: ^inbox_id, object_key: key} = saved when key == receipt.key ->
          {:ok, saved}

        _ ->
          {:error, :spool_reference_conflict}
      end
    else
      _ -> {:error, :invalid_spool_intent}
    end
  end

  def process(%Scope{} = scope, id, %Config{} = config, handler) when is_function(handler, 2) do
    if scope.repo.in_transaction?() do
      {:error, :outer_transaction}
    else
      Owner.run(fn -> do_process(scope, id, config, handler) end, 30_000)
    end
  end

  defp do_process(scope, id, config, handler) do
    now = DateTime.utc_now()
    token = Ecto.UUID.generate()

    query =
      from(i in Incoming,
        where:
          i.id == ^id and i.expires_at > ^now and
            (i.state == :pending or (i.state == :processing and i.lease_until < ^now))
      )

    case scope.repo.update_all(
           query,
           [
             set: [
               state: :processing,
               claim_id: token,
               lease_until: DateTime.add(now, 60),
               updated_at: now
             ]
           ],
           prefix: scope.prefix
         ) do
      {1, _} ->
        row = scope.repo.get!(Incoming, id, prefix: scope.prefix)

        with {:ok, content} <- SDK.fetch(config, row.object_key),
             {:ok, outcome, workflow} <- outcome(handler.(row, content)) do
          scope.repo.update_all(
            from(i in Incoming,
              where: i.id == ^id and i.claim_id == ^token and i.state == :processing
            ),
            [
              set: [
                state: :purge,
                outcome: outcome,
                workflow_id: workflow,
                updated_at: DateTime.utc_now()
              ]
            ],
            prefix: scope.prefix
          )

          purge(scope, row.id, config)
        else
          {:error, :mail_too_large} ->
            scope.repo.update_all(
              from(i in Incoming,
                where: i.id == ^id and i.claim_id == ^token and i.state == :processing
              ),
              [set: [state: :purge, outcome: :too_large, updated_at: DateTime.utc_now()]],
              prefix: scope.prefix
            )

            purge(scope, row.id, config)
            {:error, :mail_too_large}

          _ ->
            {:error, :mail_processing_failed}
        end

      _ ->
        purge(scope, id, config)
    end
  end

  defp outcome({:ok, workflow}) do
    case Ecto.UUID.cast(workflow) do
      {:ok, workflow} -> {:ok, :processed, workflow}
      _ -> {:error, :invalid_workflow}
    end
  end

  defp outcome(value) when value in [:ignored, :rejected], do: {:ok, value, nil}
  defp outcome(_), do: {:error, :invalid_workflow}

  defp purge(scope, id, config) do
    now = DateTime.utc_now()

    scope.repo.update_all(
      from(i in Incoming,
        where: i.id == ^id and i.state not in [:deleted, :purge] and i.expires_at <= ^now
      ),
      [set: [state: :purge, outcome: :expired, updated_at: now]],
      prefix: scope.prefix
    )

    case scope.repo.get(Incoming, id, prefix: scope.prefix) do
      %Incoming{state: :deleted} ->
        :ok

      %Incoming{state: :purge} = row ->
        with :ok <- SDK.delete(config, row.object_key) do
          scope.repo.update_all(
            from(i in Incoming, where: i.id == ^id and i.state == :purge),
            [set: [state: :deleted, updated_at: DateTime.utc_now()]],
            prefix: scope.prefix
          )

          :ok
        end

      _ ->
        {:error, :spool_busy}
    end
  end

  def sweep(%Scope{} = scope, %Config{} = config) do
    if scope.repo.in_transaction?() do
      {:error, :outer_transaction}
    else
      now = DateTime.utc_now()
      retire_before = DateTime.add(now, -5400)

      scope.repo.delete_all(
        from(i in Incoming, where: i.state == :deleted and i.expires_at < ^retire_before),
        prefix: scope.prefix
      )

      rows =
        scope.repo.all(
          from(i in Incoming,
            where: i.state != :deleted and (i.state == :purge or i.expires_at <= ^now),
            select: i.id,
            limit: 100
          ),
          prefix: scope.prefix
        )

      results = Enum.map(rows, &purge(scope, &1, config))
      if Enum.all?(results, &(&1 == :ok)), do: :ok, else: {:error, :spool_cleanup_failed}
    end
  end

  @doc "Delete expired orphan/unroutable objects without reading their bodies. Continue the returned marker until nil."
  def sweep_orphans(%Config{} = config, marker \\ nil) do
    with {:ok, objects, next} <- SDK.list(config, marker) do
      cutoff = DateTime.add(DateTime.utc_now(), -3600)

      results =
        Enum.map(objects, fn object ->
          with {:ok, at, _} <- DateTime.from_iso8601(object.last_modified),
               true <- DateTime.compare(at, cutoff) != :gt do
            SDK.delete(config, object.key)
          else
            false -> :ok
            _ -> {:error, :invalid_spool_metadata}
          end
        end)

      if Enum.all?(results, &(&1 == :ok)),
        do: {:ok, next},
        else: {:error, :spool_cleanup_failed, next}
    end
  end
end
