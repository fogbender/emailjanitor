defmodule EmailJanitor.SelfHost.AuthorityMigration do
  @moduledoc false
  use Ecto.Migration

  def change do
    create table(:self_host_authorities, primary_key: false) do
      add(:inbox_id, references(:inboxes, type: :text), primary_key: true)
      add(:request_id, :uuid, primary_key: true)
      add(:conversation_id, :uuid, null: false)
      add(:owner_subject, :text, null: false)
      add(:google_subject, :text, null: false)
      add(:connection_epoch, :bigint, null: false)
      add(:message_ids, {:array, :text}, null: false)
      timestamps(type: :utc_datetime_usec)
    end
  end
end

defmodule EmailJanitor.SelfHost.Grant do
  @moduledoc false
  use Ecto.Schema
  @primary_key false
  schema "self_host_authorities" do
    field(:inbox_id, :string, primary_key: true)
    field(:request_id, Ecto.UUID, primary_key: true)
    field(:conversation_id, Ecto.UUID)
    field(:owner_subject, :string)
    field(:google_subject, :string)
    field(:connection_epoch, :integer)
    field(:message_ids, {:array, :string})
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule EmailJanitor.SelfHost.Authority do
  @moduledoc "Host-authenticated, metadata-only manual retry grants; never inferred from a core candidate."
  import Ecto.Query
  alias EmailJanitor.{SelfHost, Conversation.Reference, Gmail.Parser}
  alias EmailJanitor.Store, as: CoreStore
  alias EmailJanitor.SelfHost.{Grant, Owner, Store}
  alias EmailJanitor.Conversation.Ledger.ActionBinding
  alias EmailJanitor.Store.Action
  alias EmailJanitor.Worker.Candidate

  def record(_ref, _owner, _conversation, _request, operation, _refs) when operation != :done,
    do: :ok

  def record({id, _} = ref, owner, conversation, request, :done, refs) do
    with true <- SelfHost.owner?(owner),
         {:ok, conversation} <- Ecto.UUID.cast(conversation),
         {:ok, request} <- Ecto.UUID.cast(request),
         {:ok, ids} <- references(refs, id),
         {:ok, :ok} <-
           Store.transaction(fn scope ->
             Store.lock_mailbox(scope, id)

             with {:ok, binding, _} <- Store.fetch_binding(ref) do
               values = %{
                 inbox_id: id,
                 request_id: request,
                 conversation_id: conversation,
                 owner_subject: owner,
                 google_subject: binding.google_subject,
                 connection_epoch: binding.epoch,
                 message_ids: ids
               }

               now = DateTime.utc_now()

               {inserted, _} =
                 scope.repo.insert_all(
                   Grant,
                   [Map.merge(values, %{inserted_at: now, updated_at: now})],
                   prefix: scope.prefix,
                   on_conflict: :nothing,
                   conflict_target: [:inbox_id, :request_id],
                   log: false
                 )

               saved =
                 scope.repo.get_by!(Grant, [inbox_id: id, request_id: request],
                   prefix: scope.prefix
                 )

               if saved.conversation_id != conversation or saved.owner_subject != owner or
                    saved.google_subject != binding.google_subject or
                    saved.connection_epoch != binding.epoch or
                    ids -- saved.message_ids != [],
                  do: scope.repo.rollback(:manual_authorization_changed)

               if inserted == 1 and CoreStore.fence_recheck(scope, id, ids) != :ok,
                 do: scope.repo.rollback(:manual_authorization_changed)

               :ok
             else
               _ -> scope.repo.rollback(:connection_changed)
             end
           end) do
      :ok
    else
      _ -> {:error, :manual_authorization_changed}
    end
  rescue
    _ -> {:error, :policy_unavailable}
  end

  def allow({id, _} = ref, authority, ids) do
    scope = SelfHost.scope()

    with {:ok, authority} <- Ecto.UUID.cast(authority),
         true <- is_list(ids) and length(ids) in 1..1000 and Enum.all?(ids, &Parser.valid_id?/1),
         {:ok, binding, _} <- Store.fetch_binding(ref),
         %Owner{subject: owner} <- scope.repo.get(Owner, 1, prefix: scope.prefix),
         %Grant{
           owner_subject: ^owner,
           google_subject: subject,
           connection_epoch: epoch,
           message_ids: granted
         } <-
           scope.repo.get_by(Grant, [inbox_id: id, request_id: authority], prefix: scope.prefix),
         true <-
           subject == binding.google_subject and epoch == binding.epoch and ids -- granted == [] do
      :ok
    else
      _ -> {:error, :manual_authorization_changed}
    end
  rescue
    _ -> {:error, :policy_unavailable}
  end

  @doc "Discover only this epoch's real, bound and proven-undispatched manual work."
  def discover({id, epoch} = ref, inbox) do
    scope = SelfHost.scope()

    with :ok <- Store.guard(ref, inbox),
         {:ok, binding, _} <- Store.fetch_binding(ref),
         %Owner{subject: owner} <- scope.repo.get(Owner, 1, prefix: scope.prefix, log: false) do
      rows =
        scope.repo.all(
          from(g in Grant,
            join: b in ActionBinding,
            on: b.inbox_id == g.inbox_id and b.request_id == g.request_id,
            join: a in Action,
            on: a.id == b.action_id and a.inbox_id == b.inbox_id,
            left_join: source in Candidate,
            on: source.inbox_id == a.inbox_id and source.candidate_id == a.id,
            where:
              g.inbox_id == ^id and g.connection_epoch == ^epoch and
                g.owner_subject == ^owner and g.google_subject == ^binding.google_subject and
                a.state == :cancelled and is_nil(a.dispatch_started_at) and
                fragment(
                  "cardinality(COALESCE(?, ?)) > 0",
                  a.remaining_metadata_ids,
                  a.message_ids
                ) and
                (is_nil(source.candidate_id) or
                   (source.source_kind == :manual and source.status == :pending and
                      not fragment(
                        "? <@ COALESCE(?, ?)",
                        source.message_ids,
                        a.remaining_metadata_ids,
                        a.message_ids
                      ))),
            order_by: [asc: a.updated_at, asc: a.id],
            limit: 100,
            select: {g.request_id, g.message_ids, b.message_ids, a}
          ),
          prefix: scope.prefix,
          log: false
        )

      Enum.reduce_while(rows, :ok, fn {request, granted, bound, action}, :ok ->
        ids =
          Enum.filter(
            action.remaining_metadata_ids || action.message_ids,
            &(&1 in granted and &1 in bound)
          )

        if ids == [] do
          {:cont, :ok}
        else
          case Store.transaction(fn scoped ->
                 Store.lock_mailbox(scoped, id)

                 with :ok <- Store.guard(ref, inbox),
                      :ok <- allow(ref, request, ids) do
                   EmailJanitor.Worker.queue_manual(
                     scoped,
                     inbox,
                     action.id,
                     action.thread_id,
                     ids,
                     authority_id: request,
                     refresh_authority: false
                   )
                 end
               end) do
            {:ok, :ok} -> {:cont, :ok}
            {:ok, {:error, :ineligible_recheck}} -> {:cont, :ok}
            {:error, :ineligible_recheck} -> {:cont, :ok}
            _ -> {:halt, {:error, :manual_authorization_changed}}
          end
        end
      end)
    else
      _ -> {:error, :manual_authorization_changed}
    end
  rescue
    _ -> {:error, :policy_unavailable}
  end

  defp references(values, inbox) when is_list(values) and length(values) in 1..1000 do
    ids = Enum.map(values, fn %Reference{inbox_id: ^inbox, message_id: id} -> id end)
    if Enum.all?(ids, &Parser.valid_id?/1), do: {:ok, Enum.uniq(ids)}, else: :error
  end

  defp references(_, _), do: :error
end
