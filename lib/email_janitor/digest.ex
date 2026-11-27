defmodule EmailJanitor.Digest do
  @moduledoc """
  Per-inbox local-21:00 activity ledger and frozen metadata snapshots. The host
  controls connected-inbox authorization, hypothetical eligibility and branding.
  Use deliver/5 rather than dispatching a digest's generic Outbox row directly:
  it reserves at most one digest per inbox/local delivery day, including catch-up.
  """
  import Ecto.Query
  alias EmailJanitor.Digest.{Activity, Clock, Event, Migration, Renderer, Schedule, Snapshot}
  alias EmailJanitor.Mail.{Config, Outbox, Outgoing}
  alias EmailJanitor.Store.{Mailbox, Scope}

  def install(%Scope{} = scope),
    do: Ecto.Migrator.up(scope.repo, 5, Migration, prefix: scope.prefix, log: false)

  defdelegate install_staging(scope), to: EmailJanitor.Digest.Staging, as: :install
  defdelegate stage(scope, inbox_id, event), to: EmailJanitor.Digest.Staging

  defdelegate confirm_staged(scope, inbox_id, action_id),
    to: EmailJanitor.Digest.Staging,
    as: :confirm

  def configure(%Scope{} = scope, inbox_id, timezone, %DateTime{} = now) do
    with {:ok, _, cutoff} <- Clock.cutoff(now, timezone),
         {:ok, :ok} <-
           transaction(scope, fn ->
             lock_mailbox!(scope, inbox_id)

             scope.repo.insert!(
               %Schedule{inbox_id: inbox_id, timezone: timezone, last_cutoff: cutoff},
               prefix: scope.prefix,
               on_conflict: [set: [timezone: timezone]],
               conflict_target: [:inbox_id]
             )

             :ok
           end) do
      :ok
    else
      _ -> {:error, :invalid_digest_schedule}
    end
  rescue
    _ -> {:error, :invalid_digest_schedule}
  end

  def record(%Scope{} = scope, inbox_id, %Event{} = event) do
    transaction(scope, fn ->
      lock_mailbox!(scope, inbox_id)

      row = struct(Activity, Map.from_struct(event) |> Map.put(:inbox_id, inbox_id))
      scope.repo.insert!(row, prefix: scope.prefix, on_conflict: :nothing)
      keys = [inbox_id: inbox_id, message_id: event.message_id, kind: event.kind]

      keys =
        if event.kind == :done, do: Keyword.put(keys, :source_id, event.source_id), else: keys

      saved = scope.repo.get_by!(Activity, keys, prefix: scope.prefix)

      if event.kind == :done do
        scope.repo.update_all(
          from(a in Activity,
            where:
              a.inbox_id == ^inbox_id and a.message_id == ^event.message_id and
                a.kind == :would_have_done and is_nil(a.digest_id)
          ),
          [set: [retired: true]],
          prefix: scope.prefix
        )
      end

      saved
    end)
  end

  @doc "Trusted host may retire an unlisted hypothetical after restore or another final decision."
  def retire_hypotheticals(%Scope{} = scope, inbox_id, ids) when is_list(ids) do
    case transaction(scope, fn ->
           lock_mailbox!(scope, inbox_id)

           scope.repo.update_all(
             from(a in Activity,
               where:
                 a.inbox_id == ^inbox_id and a.message_id in ^ids and
                   a.kind == :would_have_done and is_nil(a.digest_id)
             ),
             [set: [retired: true]],
             prefix: scope.prefix
           )

           :ok
         end) do
      {:ok, :ok} -> :ok
      error -> error
    end
  end

  def get(%Scope{} = scope, id), do: scope.repo.get(Snapshot, id, prefix: scope.prefix)

  @doc "Claim a due frozen snapshot and its outbox intention atomically. Callback is DB-only and shares this Repo transaction."
  def tick(%Scope{} = scope, inbox_id, %DateTime{} = now, claim_extras \\ &no_extras/4)
      when is_function(claim_extras, 4) do
    transaction(scope, fn ->
      schedule = locked_schedule!(scope, inbox_id)
      {:ok, local} = Clock.local(now, schedule.timezone)
      {:ok, date, cutoff} = Clock.cutoff(now, schedule.timezone)

      cond do
        DateTime.compare(cutoff, schedule.last_cutoff) != :gt ->
          :not_due

        delivery_day(schedule) == DateTime.to_date(local) ->
          advance(scope, schedule, cutoff)
          :daily_slot_used

        true ->
          case pending(scope, inbox_id) do
            %Snapshot{} = snapshot ->
              advance(scope, schedule, cutoff)
              {:ready, snapshot}

            nil ->
              new_snapshot(scope, schedule, date, cutoff, claim_extras)
          end
      end
    end)
  end

  def pending(%Scope{} = scope, inbox_id) do
    scope.repo.one(
      from(d in Snapshot,
        join: o in Outgoing,
        on: o.id == d.outbox_id,
        where: d.inbox_id == ^inbox_id and o.state == :pending,
        order_by: [asc: d.cutoff],
        limit: 1
      ),
      prefix: scope.prefix
    )
  end

  defp new_snapshot(scope, schedule, date, cutoff, claim_extras) do
    id = Ecto.UUID.generate()

    query =
      from(a in Activity,
        where:
          a.inbox_id == ^schedule.inbox_id and is_nil(a.digest_id) and not a.retired and
            a.occurred_at <= ^cutoff,
        order_by: [asc: a.occurred_at, asc: a.id]
      )

    {entries, _remaining} =
      scope.repo.stream(query, prefix: scope.prefix, max_rows: 500)
      |> Stream.chunk_every(500)
      |> Enum.reduce_while({[], Renderer.metadata_budget()}, fn batch, acc ->
        select_batch(scope, schedule.inbox_id, id, cutoff, claim_extras, batch, acc)
      end)

    advance(scope, schedule, cutoff)

    if entries == [] do
      :inactive
    else
      {:ok, outgoing} = Outbox.enqueue(scope, schedule.inbox_id, :digest, [id], id)

      first =
        not scope.repo.exists?(
          from(d in Snapshot,
            join: o in Outgoing,
            on: o.id == d.outbox_id,
            where: d.inbox_id == ^schedule.inbox_id and o.state == :sent
          ),
          prefix: scope.prefix
        )

      snapshot =
        scope.repo.insert!(
          %Snapshot{
            id: id,
            inbox_id: schedule.inbox_id,
            timezone: schedule.timezone,
            local_date: date,
            cutoff: cutoff,
            outbox_id: outgoing.id,
            first: first
          },
          prefix: scope.prefix
        )

      ids = Enum.map(entries, & &1.id)

      scope.repo.update_all(from(a in Activity, where: a.id in ^ids), [set: [digest_id: id]],
        prefix: scope.prefix
      )

      {:ready, snapshot}
    end
  end

  defp select_batch(_scope, _inbox, _id, _cutoff, _claim, [], acc), do: {:cont, acc}

  defp select_batch(scope, inbox_id, digest_id, cutoff, claim, batch, {entries, remaining}) do
    {prefix, rest} = take_fitting(batch, remaining)

    if prefix == [] do
      {:halt, {entries, remaining}}
    else
      eligible =
        prefix
        |> Enum.filter(&(&1.kind == :would_have_done))
        |> Enum.map(& &1.message_id)
        |> Enum.uniq()

      claimed =
        if eligible == [],
          do: [],
          else: claimed!(scope, claim.(inbox_id, digest_id, cutoff, eligible), eligible)

      accepted = Enum.filter(prefix, &(&1.kind == :done or &1.message_id in claimed))
      used = Enum.reduce(accepted, 0, &(Renderer.entry_bytes(&1) + &2))

      select_batch(
        scope,
        inbox_id,
        digest_id,
        cutoff,
        claim,
        rest,
        {entries ++ accepted, remaining - used}
      )
    end
  end

  defp take_fitting(entries, budget) do
    {prefix, _, rest} =
      Enum.reduce_while(entries, {[], budget, entries}, fn entry, {acc, left, [_ | rest]} ->
        size = Renderer.entry_bytes(entry)

        if size <= left,
          do: {:cont, {acc ++ [entry], left - size, rest}},
          else: {:halt, {acc, left, [entry | rest]}}
      end)

    {prefix, rest}
  end

  defp claimed!(scope, {:ok, ids}, eligible) when is_list(ids) do
    if length(ids) == length(Enum.uniq(ids)) and Enum.all?(ids, &(&1 in eligible)),
      do: ids,
      else: scope.repo.rollback(:invalid_digest_claim)
  end

  defp claimed!(scope, _, _), do: scope.repo.rollback(:digest_claim_failed)
  defp no_extras(_, _, _, []), do: {:ok, []}
  defp no_extras(_, _, _, _), do: {:error, :hypothetical_policy_required}

  defp locked_schedule!(scope, inbox_id) do
    lock_mailbox!(scope, inbox_id)

    scope.repo.one(from(s in Schedule, where: s.inbox_id == ^inbox_id, lock: "FOR UPDATE"),
      prefix: scope.prefix
    ) || scope.repo.rollback(:unknown_digest_schedule)
  end

  defp lock_mailbox!(scope, inbox_id) do
    scope.repo.one(from(m in Mailbox, where: m.id == ^inbox_id, lock: "FOR UPDATE"),
      prefix: scope.prefix
    ) ||
      scope.repo.rollback(:unknown_digest_schedule)
  end

  defp advance(scope, schedule, cutoff),
    do:
      scope.repo.update_all(
        from(s in Schedule, where: s.inbox_id == ^schedule.inbox_id),
        [set: [last_cutoff: cutoff]],
        prefix: scope.prefix
      )

  def render(%Scope{} = scope, id, footer \\ "") do
    with %Snapshot{} = snapshot <- get(scope, id) do
      entries =
        scope.repo.all(
          from(a in Activity,
            where: a.digest_id == ^id,
            order_by: [asc: a.occurred_at, asc: a.id]
          ),
          prefix: scope.prefix
        )

      Renderer.message(snapshot, entries, footer)
    else
      _ -> {:error, :unknown_digest}
    end
  end

  @doc "Reserve the fresh local dispatch day atomically with the outbox fence."
  def deliver(%Scope{} = scope, id, %Config{} = config, authorize, opts \\ []) do
    with %Snapshot{} = snapshot <- get(scope, id) do
      clock = Keyword.get(opts, :clock, &DateTime.utc_now/0)
      footer = Keyword.get(opts, :footer, "")
      admission = fn _ -> admit(scope, snapshot, clock.()) end

      Outbox.deliver(
        scope,
        snapshot.outbox_id,
        config,
        authorize,
        fn _ -> render(scope, id, footer) end,
        admission
      )
    else
      _ -> {:error, :unknown_digest}
    end
  end

  defp admit(scope, snapshot, now) do
    schedule = locked_schedule!(scope, snapshot.inbox_id)
    {:ok, local} = Clock.local(now, schedule.timezone)
    date = DateTime.to_date(local)

    prior = delivery_day(schedule)

    if DateTime.compare(now, snapshot.cutoff) == :lt or
         (prior &&
            (Date.compare(date, prior) == :lt or
               (prior == date and schedule.delivery_digest_id != snapshot.id))) do
      {:error, :daily_slot_used}
    else
      scope.repo.update_all(
        from(s in Schedule, where: s.inbox_id == ^snapshot.inbox_id),
        [
          set: [
            delivery_date: date,
            delivery_at: %{now | microsecond: {elem(now.microsecond, 0), 6}},
            delivery_digest_id: snapshot.id
          ]
        ],
        prefix: scope.prefix
      )

      :ok
    end
  end

  defp delivery_day(%Schedule{delivery_at: nil}), do: nil

  defp delivery_day(schedule) do
    {:ok, local} = Clock.local(schedule.delivery_at, schedule.timezone)
    DateTime.to_date(local)
  end

  defp transaction(scope, fun) do
    case scope.repo.transaction(fun) do
      {:ok, result} ->
        {:ok, result}

      {:error, reason}
      when reason in [
             :unknown_digest_schedule,
             :digest_claim_failed,
             :invalid_digest_claim,
             :unknown_digest,
             :daily_slot_used,
             :digest_not_due
           ] ->
        {:error, reason}

      _ ->
        {:error, :digest_unavailable}
    end
  rescue
    _ -> {:error, :digest_unavailable}
  catch
    _, _ -> {:error, :digest_unavailable}
  end
end
