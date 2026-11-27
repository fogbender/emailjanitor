defmodule EmailJanitor.Mail.Receiver do
  @moduledoc "Independent receipt intake, body disposal, authenticated feedback and TTL cleanup jobs."
  import Ecto.Query
  alias EmailJanitor.Mail.{Feedback, Incoming, Receipt, SDK, Spool}
  alias EmailJanitor.Mail.Job

  def children(%Feedback.Config{} = config) do
    [
      job(:receipt_intake, fn _ -> receive_once(config) end, 45_000),
      job(:incoming_processing, fn _ -> process_once(config) end, 40_000),
      job(:authenticated_feedback, fn _ -> feedback_once(config) end, 1_100_000),
      job(:feedback_metadata_cleanup, fn _ -> purge_feedback(config) end, 30_000),
      job(:spool_cleanup, fn marker -> sweep(config, marker) end, 1_100_000),
      job(:orphan_cleanup, fn marker -> sweep_orphans(config, marker) end, 1_100_000)
    ]
  end

  defp job(name, run, timeout) do
    Supervisor.child_spec({Job, run: run, timeout_ms: timeout}, id: name)
  end

  @doc false
  def receive_once(config) do
    case SDK.poll(config.mail) do
      {:ok, deliveries} ->
        for delivery <- deliveries do
          case Receipt.parse(config.mail, delivery.body) do
            {:ok, receipt} ->
              case Spool.accept(config.transport_scope, config.transport_inbox.id, receipt) do
                {:ok, _} -> SDK.acknowledge(config.mail, delivery.handle)
                _ -> :retry
              end

            _ ->
              SDK.acknowledge(config.mail, delivery.handle)
          end
        end

        {:next, nil, 1_000}

      _ ->
        {:next, nil, 60_000}
    end
  end

  @doc false
  def process_once(config) do
    scope = config.transport_scope
    now = DateTime.utc_now()

    id =
      scope.repo.one(
        from(i in Incoming,
          where:
            i.inbox_id == ^config.transport_inbox.id and i.expires_at > ^now and
              (i.state == :pending or (i.state == :processing and i.lease_until < ^now)),
          order_by: [asc: i.updated_at, asc: i.id],
          limit: 1,
          select: i.id
        ),
        prefix: scope.prefix,
        log: false
      )

    if id do
      result =
        Spool.process(scope, id, config.mail, fn incoming, raw ->
          Feedback.accept(config, incoming, raw)
        end)

      {:next, nil, if(result == :ok, do: 0, else: 1_000)}
    else
      {:next, nil, 1_000}
    end
  end

  @doc false
  def feedback_once(config) do
    case Feedback.tick(config) do
      {:ok, :idle} -> {:next, nil, 1_000}
      {:ok, _} -> {:next, nil, 0}
      _ -> {:next, nil, 60_000}
    end
  end

  @doc false
  def purge_feedback(config) do
    case Feedback.Ledger.purge(config.transport_scope, DateTime.utc_now()) do
      :ok -> {:next, nil, 60_000}
      _ -> :failed
    end
  end

  @doc false
  def sweep(config, marker),
    do: continuation(Spool.sweep(config.transport_scope, config.mail, marker))

  @doc false
  def sweep_orphans(config, marker), do: continuation(Spool.sweep_orphans(config.mail, marker))

  defp continuation({:ok, next}), do: {:next, next, if(is_nil(next), do: 60_000, else: 0)}

  defp continuation({:error, :spool_cleanup_failed, next}),
    do: {:next, next, if(is_nil(next), do: 60_000, else: 0)}

  defp continuation(_), do: :failed
end
