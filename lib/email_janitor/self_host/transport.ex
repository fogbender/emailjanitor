defmodule EmailJanitor.SelfHost.Transport do
  @moduledoc "A fixed mail-spool anchor, never a connected Google inbox or cleanup target."
  alias EmailJanitor.{Inbox, SelfHost}
  alias EmailJanitor.SelfHost.Adapters
  alias EmailJanitor.Store.Mailbox
  @id "selfhost-mail-transport"

  def inbox(config) do
    with {:ok, mail} <- Adapters.mail(config), do: Inbox.new(@id, mail.sender)
  end

  def install(config) do
    with {:ok, inbox} <- inbox(config) do
      scope = SelfHost.scope()

      case scope.repo.transaction(fn ->
             EmailJanitor.Preferences.Lock.acquire(scope, :shared)
             now = DateTime.utc_now()

             scope.repo.insert_all(
               Mailbox,
               [
                 %{
                   id: inbox.id,
                   address: inbox.address,
                   instruction_version: 1,
                   inserted_at: now,
                   updated_at: now
                 }
               ],
               prefix: scope.prefix,
               on_conflict: :nothing,
               log: false
             )

             case scope.repo.get(Mailbox, inbox.id, prefix: scope.prefix, log: false) do
               %Mailbox{address: address} when address == inbox.address -> :ok
               _ -> scope.repo.rollback(:transport_identity_changed)
             end
           end) do
        {:ok, :ok} -> :ok
        _ -> {:error, :transport_unavailable}
      end
    end
  rescue
    _ -> {:error, :transport_unavailable}
  end
end
