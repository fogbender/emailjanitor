defmodule EmailJanitor.Preferences do
  @moduledoc "Versioned distilled instructions. Raw email, conversations and model responses never belong here."
  import Ecto.Query
  alias EmailJanitor.Content
  alias EmailJanitor.Store.{Mailbox, Scope}
  alias __MODULE__.{Change, Lock, Row, Snapshot}

  defmodule Row do
    @moduledoc false
    use Ecto.Schema
    @derive {Inspect, only: [:key, :revision]}
    @primary_key {:key, :string, autogenerate: false}
    schema "preferences" do
      field(:instruction, :string)
      field(:revision, :integer)
      timestamps(type: :utc_datetime_usec)
    end
  end

  defmodule Change do
    @moduledoc "A durable effect receipt, containing no email or conversation text."
    use Ecto.Schema
    @primary_key {:id, Ecto.UUID, autogenerate: false}
    schema "preference_changes" do
      field(:target_key, :string)
      field(:instruction_hash, :binary)
      field(:revision, :integer)
      field(:changed, :boolean)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end
  end

  defmodule Snapshot do
    @moduledoc "Transient planner context with revisions for a conditional update."
    @derive {Inspect, only: [:inbox_id, :instruction_version, :global_revision, :local_revision]}
    @enforce_keys [
      :scope_prefix,
      :inbox_id,
      :instruction_version,
      :global_revision,
      :local_revision,
      :global,
      :local
    ]
    defstruct @enforce_keys
  end

  def install(%Scope{} = scope),
    do: Ecto.Migrator.up(scope.repo, 3, __MODULE__.Migration, prefix: scope.prefix, log: false)

  def snapshot(%Scope{} = scope, inbox_id) do
    transaction(scope, fn ->
      Lock.acquire(scope, :shared)

      mailbox =
        scope.repo.one(from(m in Mailbox, where: m.id == ^inbox_id, lock: "FOR SHARE"),
          prefix: scope.prefix,
          log: false
        ) || scope.repo.rollback(:unknown_inbox)

      snapshot_value(scope, mailbox)
    end)
  end

  def text(%Snapshot{} = snapshot) do
    Content.new(
      "All inboxes:\n" <>
        Content.read(snapshot.global) <>
        "\nThis inbox:\n" <> Content.read(snapshot.local)
    )
  end

  @doc "Replace one instruction scope after a planner has distilled the user's correction. No model I/O in this transaction."
  def replace(
        %Scope{} = scope,
        target,
        %Snapshot{} = expected,
        %Content{} = distilled,
        request_id
      ) do
    instruction = Content.read(distilled)

    with {:ok, id} <- Ecto.UUID.cast(request_id),
         true <- expected.scope_prefix == scope.prefix,
         {:ok, key} <- target_key(target, expected.inbox_id),
         true <-
           byte_size(instruction) <= 15_000 and String.valid?(instruction) and
             not String.contains?(instruction, <<0>>) do
      hash = :crypto.hash(:sha256, instruction)

      transaction(scope, fn ->
        Lock.acquire(scope, :exclusive)
        # Registration takes the shared namespace lock, so a newly registered
        # inbox cannot miss a concurrent global instruction-version increment.
        mailboxes =
          scope.repo.all(from(m in Mailbox, order_by: [asc: m.id], lock: "FOR UPDATE"),
            prefix: scope.prefix,
            log: false
          )

        mailbox =
          Enum.find(mailboxes, &(&1.id == expected.inbox_id)) ||
            scope.repo.rollback(:unknown_inbox)

        case scope.repo.get(Change, id, prefix: scope.prefix, log: false) do
          %Change{target_key: ^key, instruction_hash: ^hash} = receipt -> receipt
          %Change{} -> scope.repo.rollback(:request_conflict)
          nil -> update(scope, mailbox, key, instruction, hash, expected, id)
        end
      end)
    else
      _ -> {:error, :invalid_instruction}
    end
  end

  defp update(scope, mailbox, key, instruction, hash, expected, id) do
    current = snapshot_value(scope, mailbox)

    if current.instruction_version != expected.instruction_version or
         current.global_revision != expected.global_revision or
         current.local_revision != expected.local_revision,
       do: scope.repo.rollback(:instructions_changed)

    old = scope.repo.get(Row, key, prefix: scope.prefix, log: false)
    changed = instruction != if(old, do: old.instruction, else: "")
    revision = if(old, do: old.revision, else: 0)
    revision = if changed, do: revision + 1, else: revision

    if changed do
      (old || %Row{key: key})
      |> Ecto.Changeset.change(instruction: instruction, revision: revision)
      |> scope.repo.insert_or_update!(prefix: scope.prefix, log: false)

      query = if key == "all", do: Mailbox, else: from(m in Mailbox, where: m.id == ^mailbox.id)

      scope.repo.update_all(
        query,
        [inc: [instruction_version: 1], set: [updated_at: DateTime.utc_now()]],
        prefix: scope.prefix,
        log: false
      )
    end

    scope.repo.insert!(
      %Change{
        id: id,
        target_key: key,
        instruction_hash: hash,
        revision: revision,
        changed: changed
      },
      prefix: scope.prefix,
      log: false
    )
  end

  defp snapshot_value(scope, mailbox) do
    global = scope.repo.get(Row, "all", prefix: scope.prefix, log: false)
    local = scope.repo.get(Row, "inbox:" <> mailbox.id, prefix: scope.prefix, log: false)

    %Snapshot{
      scope_prefix: scope.prefix,
      inbox_id: mailbox.id,
      instruction_version: mailbox.instruction_version,
      global_revision: if(global, do: global.revision, else: 0),
      local_revision: if(local, do: local.revision, else: 0),
      global: Content.new(if(global, do: global.instruction, else: "")),
      local: Content.new(if(local, do: local.instruction, else: ""))
    }
  end

  defp target_key(:all, _), do: {:ok, "all"}
  defp target_key({:inbox, id}, id), do: {:ok, "inbox:" <> id}
  defp target_key(_, _), do: {:error, :invalid_target}

  defp transaction(scope, fun) do
    if scope.repo.in_transaction?(),
      do: {:error, :outer_transaction},
      else: scope.repo.transaction(fun)
  rescue
    _ -> {:error, :preferences_unavailable}
  catch
    _, _ -> {:error, :preferences_unavailable}
  end
end
