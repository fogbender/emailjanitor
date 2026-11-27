defmodule EmailJanitor.Mail.Feedback.Ledger do
  @moduledoc false
  import Ecto.Query, except: [update: 2, update: 3]
  alias EmailJanitor.Mail.Feedback.Record
  # Shared Receiver's 1,100s watchdog exceeds Sent readback + the 900s core
  # conversation + reply dispatch; keep its durable claim beyond that budget.
  @claim_lease_seconds 1200

  def get(scope, id), do: scope.repo.get(Record, id, prefix: scope.prefix)

  def insert(scope, %Record{} = row) do
    scope.repo.insert!(row, prefix: scope.prefix, on_conflict: :nothing, conflict_target: [:id])
    saved = get(scope, row.id)

    if saved.kind == row.kind and saved.sender_address == row.sender_address and
         saved.sender_inbox_id == row.sender_inbox_id and
         (row.kind == :signup or
            (saved.rfc_message_id == row.rfc_message_id and saved.route_key == row.route_key)),
       do: {:ok, saved},
       else: {:error, :feedback_reference_conflict}
  end

  # These are abuse/resource ceilings for unverified SMTP hints, not product
  # suppression allowances. A failed DMARC verdict is rejected even earlier.
  def admit(scope, %Record{kind: :feedback} = row, guard \\ nil) do
    case scope.repo.transaction(fn ->
           Ecto.Adapters.SQL.query!(
             scope.repo,
             "SELECT pg_advisory_xact_lock(hashtextextended($1,0))",
             ["feedback-admission:" <> scope.prefix],
             log: false
           )

           case admission_guard(guard) do
             :ok -> :ok
             {:error, :connection_changed} -> scope.repo.rollback(:feedback_connection_changed)
             _ -> scope.repo.rollback(:feedback_unavailable)
           end

           if get(scope, row.id) do
             insert(scope, row)
           else
             now = DateTime.utc_now()

             pending =
               from(r in Record,
                 where:
                   r.kind == :feedback and
                     r.state in [
                       :pending,
                       :processing,
                       :waiting_sent,
                       :workflow_retry,
                       :reply_pending
                     ] and
                     ((is_nil(r.authenticated_at) and r.expires_at > ^now) or
                        (not is_nil(r.authenticated_at) and
                           r.authenticated_at > ^DateTime.add(now, -3600)))
               )

             sender = from(r in pending, where: r.sender_inbox_id == ^row.sender_inbox_id)

             if scope.repo.aggregate(sender, :count, prefix: scope.prefix) >= 20 or
                  scope.repo.aggregate(pending, :count, prefix: scope.prefix) >= 1000,
                do: scope.repo.rollback(:feedback_rate_limited)

             insert(scope, row)
           end
         end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp admission_guard(nil), do: :ok
  defp admission_guard(guard) when is_function(guard, 0), do: guard.()
  defp admission_guard(_), do: {:error, :feedback_unavailable}

  def due(scope, now) do
    scope.repo.one(
      from(r in Record,
        where:
          (r.state in [:pending, :waiting_sent, :workflow_retry, :reply_pending] and
             (is_nil(r.next_attempt_at) or r.next_attempt_at <= ^now)) or
            (r.state == :processing and r.lease_until < ^now),
        order_by: [asc_nulls_last: r.authenticated_at, asc: r.inserted_at, asc: r.id],
        limit: 1
      ),
      prefix: scope.prefix
    )
  end

  def claim_next(scope, now) do
    case scope.repo.transaction(fn ->
           query =
             from(r in Record,
               where:
                 (r.state in [:pending, :waiting_sent, :workflow_retry, :reply_pending] and
                    (is_nil(r.next_attempt_at) or r.next_attempt_at <= ^now)) or
                   (r.state == :processing and r.lease_until < ^now),
               order_by: [asc_nulls_last: r.authenticated_at, asc: r.inserted_at, asc: r.id],
               limit: 1,
               lock: "FOR UPDATE SKIP LOCKED"
             )

           case scope.repo.one(query, prefix: scope.prefix) do
             nil -> :idle
             row -> claim(scope, row.id, now)
           end
         end) do
      {:ok, result} -> result
      _ -> {:error, :feedback_unavailable}
    end
  end

  def claim(scope, id, now) do
    token = Ecto.UUID.generate()

    query =
      from(r in Record,
        where:
          r.id == ^id and
            ((r.state in [:pending, :waiting_sent, :workflow_retry, :reply_pending] and
                (is_nil(r.next_attempt_at) or r.next_attempt_at <= ^now)) or
               (r.state == :processing and r.lease_until < ^now))
      )

    case scope.repo.transaction(fn ->
           old = scope.repo.one(from(r in query, lock: "FOR UPDATE"), prefix: scope.prefix)
           if is_nil(old), do: scope.repo.rollback(:feedback_busy)

           scope.repo.update_all(
             query,
             [
               set: [
                 state: :processing,
                 claim_id: token,
                 lease_until: DateTime.add(now, @claim_lease_seconds),
                 updated_at: now
               ]
             ],
             prefix: scope.prefix
           )

           {get(scope, id), old.state}
         end) do
      {:ok, {row, previous}} -> {:ok, row, previous}
      _ -> {:error, :feedback_busy}
    end
  end

  def update(scope, %Record{} = row, changes) do
    now = DateTime.utc_now()

    query =
      from(r in Record,
        where: r.id == ^row.id and r.claim_id == ^row.claim_id and r.state == :processing
      )

    case scope.repo.update_all(
           query,
           [set: Keyword.merge([updated_at: now], Map.to_list(changes))],
           prefix: scope.prefix
         ) do
      {1, _} -> {:ok, get(scope, row.id)}
      _ -> {:error, :feedback_claim_changed}
    end
  end

  def retry(scope, row, state, now) do
    attempts = min(row.attempts + 1, 16)
    delay = min(15 * Integer.pow(2, min(attempts - 1, 5)), 300)

    update(scope, row, %{
      state: state,
      attempts: attempts,
      next_attempt_at: DateTime.add(now, delay),
      lease_until: nil
    })
  end

  def purge(scope, now) do
    cutoff = DateTime.add(now, -7 * 86400)

    query =
      from(r in Record,
        where:
          r.inserted_at < ^cutoff and
            (r.state != :processing or is_nil(r.lease_until) or r.lease_until < ^now),
        limit: 1000,
        lock: "FOR UPDATE SKIP LOCKED",
        select: {r.id, r.kind, r.sender_inbox_id}
      )

    result =
      scope.repo.transaction(fn ->
        rows = scope.repo.all(query, prefix: scope.prefix)
        ids = Enum.map(rows, &elem(&1, 0))
        # Signup recipients have no Google identity/actions. Remove their exact old
        # reply metadata first, then the unused synthetic transport-only mailbox.

        for inbox_id <-
              rows
              |> Enum.flat_map(fn {_, kind, inbox} ->
                if kind == :signup, do: [inbox], else: []
              end)
              |> Enum.uniq()
              |> Enum.sort() do
          scope.repo.one(
            from(m in EmailJanitor.Store.Mailbox, where: m.id == ^inbox_id, lock: "FOR UPDATE"),
            prefix: scope.prefix
          )
        end

        for {id, :signup, inbox_id} <- rows do
          scope.repo.delete_all(
            from(o in EmailJanitor.Mail.Outgoing,
              where: o.inbox_id == ^inbox_id and o.kind == :assistant and o.dedupe_id == ^id
            ),
            prefix: scope.prefix
          )
        end

        scope.repo.delete_all(from(r in Record, where: r.id in ^ids), prefix: scope.prefix)

        for {_, :signup, inbox_id} <- rows do
          unless scope.repo.exists?(from(r in Record, where: r.sender_inbox_id == ^inbox_id),
                   prefix: scope.prefix
                 ) or
                   scope.repo.exists?(
                     from(o in EmailJanitor.Mail.Outgoing, where: o.inbox_id == ^inbox_id),
                     prefix: scope.prefix
                   ) do
            scope.repo.delete_all(from(m in EmailJanitor.Store.Mailbox, where: m.id == ^inbox_id),
              prefix: scope.prefix
            )
          end
        end
      end)

    case result do
      {:ok, _} -> :ok
      _ -> {:error, :feedback_cleanup_unavailable}
    end
  end
end
