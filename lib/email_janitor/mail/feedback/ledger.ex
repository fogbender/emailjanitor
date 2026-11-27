defmodule EmailJanitor.Mail.Feedback.Ledger do
  @moduledoc false
  import Ecto.Query, except: [update: 2, update: 3]
  alias EmailJanitor.Mail.Feedback.Record

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

  def due(scope, now) do
    scope.repo.one(
      from(r in Record,
        where:
          (r.state in [:pending, :waiting_sent, :workflow_retry, :reply_pending] and
             (is_nil(r.next_attempt_at) or r.next_attempt_at <= ^now)) or
            (r.state == :processing and r.lease_until < ^now),
        order_by: [asc: r.inserted_at, asc: r.id],
        limit: 1
      ),
      prefix: scope.prefix
    )
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
                 lease_until: DateTime.add(now, 1000),
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

    ids =
      from(r in Record,
        where: r.inserted_at < ^cutoff and r.state != :processing,
        limit: 1000,
        select: r.id
      )

    scope.repo.delete_all(from(r in Record, where: r.id in subquery(ids)), prefix: scope.prefix)
    :ok
  end
end
