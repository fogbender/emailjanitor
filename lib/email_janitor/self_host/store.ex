defmodule EmailJanitor.SelfHost.Store do
  @moduledoc "Single immutable owner and encrypted Google connection bindings, without tenancy."
  import Ecto.Query
  alias EmailJanitor.{Address, Content, Digest, Inbox, SelfHost}
  alias EmailJanitor.Google.OAuth

  alias EmailJanitor.SelfHost.{
    Binding,
    Grants,
    HistoricalAddress,
    Migration,
    Owner,
    Refreshes,
    Revocations
  }

  alias EmailJanitor.Store.Mailbox

  def install(
        %EmailJanitor.Store.Scope{repo: EmailJanitor.SelfHost.Repo, prefix: "ej_selfhost"} = scope
      ) do
    result = Ecto.Migrator.up(scope.repo, 100, Migration, prefix: scope.prefix, log: false)

    if result in [:ok, :already_up] do
      case Revocations.install(scope) do
        result when result in [:ok, :already_up] -> Grants.install(scope)
        result -> result
      end
    else
      result
    end
  end

  def install(_), do: {:error, :invalid_self_host_scope}

  @doc false
  def recipient?(inbox_id, recipient) do
    scope = SelfHost.scope()

    scope.repo.exists?(
      from(a in HistoricalAddress, where: a.inbox_id == ^inbox_id and a.address == ^recipient),
      prefix: scope.prefix,
      log: false
    )
  end

  @doc false
  def self_delivery?(inbox_id, sender, headers) do
    EmailJanitor.Mail.Outbox.self_delivery?(
      SelfHost.scope(),
      inbox_id,
      sender,
      headers,
      &recipient?(inbox_id, &1)
    )
  end

  def owner?(subject) when is_binary(subject) do
    scope = SelfHost.scope()

    scope.repo.exists?(from(o in Owner, where: o.id == 1 and o.subject == ^subject),
      prefix: scope.prefix,
      log: false
    )
  rescue
    _ -> false
  end

  def owner?(_), do: false

  def authorize_owner(%OAuth.Result{} = result) do
    with {:ok, email} <- Address.normalize(result.email), true <- subject?(result.subject) do
      transaction(fn scope ->
        if scope.repo.get(Owner, 1, prefix: scope.prefix) == nil do
          if email != SelfHost.config().owner_email, do: scope.repo.rollback(:unauthorized)

          scope.repo.insert!(%Owner{id: 1, subject: result.subject, email: email},
            prefix: scope.prefix,
            on_conflict: :nothing
          )
        end

        if !owner?(result.subject), do: scope.repo.rollback(:unauthorized)
        result.subject
      end)
    else
      _ -> {:error, :unauthorized}
    end
  end

  def authorize_owner(_), do: {:error, :unauthorized}

  def connect(subject, result, timezone) do
    if owner?(subject), do: connect_verified(result, timezone), else: {:error, :unauthorized}
  end

  defp connect_verified(%OAuth.Result{} = result, timezone) do
    with true <- subject?(result.subject),
         {:ok, box} <- Inbox.new(inbox_id(result.subject), result.email),
         {:ok, token} <- token_data(result.token, require_mail_scope: false),
         {:ok, cipher} <- SelfHost.seal("gmail-token", box.id, result.token) do
      valid =
        match?({:ok, _}, token_data(result.token)) and
          token["expires_at"] > System.system_time(:second) and is_binary(timezone) and
          byte_size(timezone) <= 255 and
          match?({:ok, _}, Digest.Clock.local(DateTime.utc_now(), timezone))

      with {:ok, capture} <- capture_verified(result, box, cipher, timezone, valid) do
        if capture.blocked do
          {:error, :revocation_pending}
        else
          transaction(fn scope ->
            # Match the core's preference/inbox insertion ordering for a new inbox.
            # Only connect changes multiple bindings. Worker/disconnect never acquire
            # this host-only lock after taking a scoped mailbox lock.
            scope.repo.query!(
              "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
              ["emailjanitor/selfhost/connect"],
              log: false
            )

            EmailJanitor.Preferences.Lock.acquire(scope, :shared)
            now = DateTime.utc_now()

            scope.repo.insert_all(
              Mailbox,
              [
                %{
                  id: box.id,
                  address: box.address,
                  instruction_version: 1,
                  inserted_at: now,
                  updated_at: now
                }
              ],
              prefix: scope.prefix,
              on_conflict: :nothing
            )

            mailbox = lock_mailbox(scope, box.id)

            binding = scope.repo.get(Binding, box.id, prefix: scope.prefix)
            readdressed = mailbox.address != box.address

            if readdressed and is_nil(binding) do
              Revocations.stage_unbound!(scope, box.id, result.subject)
              {:refused, :invalid_connection}
            else
              binding =
                binding ||
                  %Binding{
                    id: box.id,
                    google_subject: result.subject,
                    timezone: if(valid, do: timezone, else: "Etc/UTC"),
                    state: :pending
                  }

              if binding.google_subject != result.subject,
                do: scope.repo.rollback(:invalid_connection)

              # Capture both capabilities BEFORE activation or a refused callback commits.
              # Superseded grants stay dormant until disconnect: revoking one now could
              # invalidate the newly accepted project-wide grant too.
              Grants.retain_cipher!(scope, box.id, binding.token_ciphertext)

              cond do
                binding.token_version != capture.version or binding.epoch != capture.epoch ->
                  {:refused, :connection_changed}

                Revocations.blocked?(scope, result.subject) ->
                  Revocations.stage!(scope, binding, new_grant: true)
                  {:refused, :revocation_pending}

                not valid ->
                  if binding.state in [:disconnected, :revoking, :revocation_required] or
                       (binding.state == :pending and is_nil(binding.token_ciphertext)) do
                    state = Revocations.stage!(scope, binding)

                    scope.repo.insert_or_update!(
                      Ecto.Changeset.change(binding, state: state, token_ciphertext: nil),
                      prefix: scope.prefix,
                      log: false
                    )
                  end

                  {:refused, :invalid_connection}

                true ->
                  retire_replaced_subjects(scope, result.subject, box.address)
                  resumed = binding.state != :disconnected

                  if readdressed do
                    readdress_checkpoint!(scope, box.id, mailbox.address, box.address)

                    scope.repo.update_all(
                      from(m in Mailbox, where: m.id == ^box.id),
                      [
                        inc: [instruction_version: 1],
                        set: [address: box.address, updated_at: now]
                      ],
                      prefix: scope.prefix
                    )
                  end

                  # History belongs to this immutable Google subject, never a reused address.
                  for address <- Enum.uniq([mailbox.address, box.address]) do
                    scope.repo.insert_all(
                      HistoricalAddress,
                      [%{inbox_id: box.id, address: address}],
                      prefix: scope.prefix,
                      on_conflict: :nothing,
                      log: false
                    )
                  end

                  changes = %{
                    timezone: timezone,
                    token_ciphertext: cipher,
                    token_version: binding.token_version + 1,
                    state: if(binding.state == :active, do: :active, else: :pending),
                    reset_baseline: binding.reset_baseline or not resumed,
                    epoch:
                      if(resumed and not readdressed, do: binding.epoch, else: binding.epoch + 1)
                  }

                  scope.repo.insert_or_update!(Ecto.Changeset.change(binding, changes),
                    prefix: scope.prefix
                  )

                  :ok = Digest.configure(scope, box.id, timezone, now)
                  box
              end
            end
          end)
          |> case do
            {:ok, {:refused, reason}} -> {:error, reason}
            result -> result
          end
        end
      end
    else
      _ -> {:error, :invalid_connection}
    end
  rescue
    _ -> {:error, :invalid_connection}
  end

  defp connect_verified(_, _), do: {:error, :invalid_connection}

  # This transaction commits the SDK result before any publication/CAS/business
  # validation can roll back. A failed publication leaves every capability owned.
  defp capture_verified(result, box, cipher, timezone, valid) do
    transaction(fn scope ->
      scope.repo.query!(
        "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
        ["emailjanitor/selfhost/connect"],
        log: false
      )

      EmailJanitor.Preferences.Lock.acquire(scope, :shared)
      now = DateTime.utc_now()

      scope.repo.insert_all(
        Mailbox,
        [
          %{
            id: box.id,
            address: box.address,
            instruction_version: 1,
            inserted_at: now,
            updated_at: now
          }
        ],
        prefix: scope.prefix,
        on_conflict: :nothing,
        log: false
      )

      mailbox = lock_mailbox(scope, box.id)
      binding = scope.repo.get(Binding, box.id, prefix: scope.prefix, log: false)

      if binding && binding.google_subject != result.subject,
        do: scope.repo.rollback(:invalid_connection)

      # A legacy mailbox with no verified binding must never gain authority to
      # historical actions just because a new profile reuses its address/ID.
      binding =
        if is_nil(binding) and mailbox.address == box.address do
          scope.repo.insert!(
            %Binding{
              id: box.id,
              google_subject: result.subject,
              timezone: if(valid, do: timezone, else: "Etc/UTC"),
              state: :pending
            },
            prefix: scope.prefix,
            log: false
          )
        else
          binding
        end

      Grants.retain!(scope, box.id, result.token, cipher)
      blocked = Revocations.blocked?(scope, result.subject)
      Revocations.note_capture!(scope, box.id)

      %{
        version: binding && binding.token_version,
        epoch: binding && binding.epoch,
        blocked: blocked
      }
    end)
  end

  def inboxes(subject) do
    if owner?(subject) do
      scope = SelfHost.scope()

      rows =
        scope.repo.all(
          from(b in Binding,
            join: m in Mailbox,
            on: m.id == b.id,
            order_by: m.address,
            select: {b.id, m.address, b.state, b.timezone}
          ),
          prefix: scope.prefix
        )

      {:ok,
       Enum.map(rows, fn {id, address, state, timezone} ->
         %{inbox: %Inbox{id: id, address: address}, state: state, timezone: timezone}
       end)}
    else
      {:error, :unauthorized}
    end
  rescue
    _ -> {:error, :self_host_unavailable}
  end

  def inbox(subject, id) do
    with {:ok, rows} <- inboxes(subject),
         %{inbox: box, state: state} when state in [:pending, :active] <-
           Enum.find(rows, &(&1.inbox.id == id)) do
      {:ok, box}
    else
      {:error, _} = error -> error
      _ -> {:error, :inbox_unavailable}
    end
  end

  def disconnect(subject, id) do
    if owner?(subject) do
      case transaction(fn scope ->
             lock_mailbox(scope, id)

             case scope.repo.get(Binding, id, prefix: scope.prefix) do
               nil ->
                 scope.repo.rollback(:inbox_unavailable)

               %Binding{state: state}
               when state in [:revoking, :revocation_required] ->
                 :ok

               %Binding{state: :disconnected} = binding ->
                 if Grants.next(scope, id) || Refreshes.uncertain?(scope, id),
                   do: stage_disconnect!(scope, binding, id),
                   else: :ok

               binding ->
                 stage_disconnect!(scope, binding, id)
             end
           end) do
        {:ok, :ok} -> :ok
        error -> error
      end
    else
      {:error, :unauthorized}
    end
  end

  defp stage_disconnect!(scope, binding, id) do
    state = Revocations.stage!(scope, binding)

    scope.repo.update!(
      Ecto.Changeset.change(binding,
        state: state,
        reset_baseline: true,
        reset_generation: checkpoint_generation(scope, id),
        token_ciphertext: nil,
        epoch: binding.epoch + 1,
        token_version: binding.token_version + 1
      ),
      prefix: scope.prefix
    )

    scope.repo.update_all(
      from(m in Mailbox, where: m.id == ^id),
      [inc: [instruction_version: 1], set: [updated_at: DateTime.utc_now()]],
      prefix: scope.prefix
    )

    :ok
  end

  @doc false
  # Internal lifecycle pairs. Worker.Server requires the opaque binary adapter
  # below; tuples must never be passed directly as its list callback results.
  def refs do
    scope = SelfHost.scope()

    {:ok,
     scope.repo.all(
       from(b in Binding,
         where: b.state in [:pending, :active],
         order_by: b.id,
         select: {b.id, b.epoch}
       ),
       prefix: scope.prefix
     )}
  rescue
    _ -> {:error, :self_host_unavailable}
  end

  @doc "Bounded opaque keys for Worker.Server's trusted list callback."
  def worker_refs do
    with {:ok, refs} <- refs() do
      {:ok,
       Enum.map(refs, fn {id, epoch} ->
         [id, epoch] |> Jason.encode!() |> Base.url_encode64(padding: false)
       end)}
    end
  end

  def fetch_binding(key) when is_binary(key) and byte_size(key) in 1..256 do
    with {:ok, json} <- Base.url_decode64(key, padding: false),
         {:ok, [id, epoch]} <- Jason.decode(json),
         true <- is_binary(id) and byte_size(id) in 1..200 and is_integer(epoch) and epoch > 0 do
      fetch_binding({id, epoch})
    else
      _ -> {:error, :inbox_unavailable}
    end
  rescue
    _ -> {:error, :inbox_unavailable}
  end

  @doc false
  def fetch_binding({id, epoch}) when is_binary(id) and is_integer(epoch) do
    scope = SelfHost.scope()

    case scope.repo.one(
           from(b in Binding,
             join: m in Mailbox,
             on: m.id == b.id,
             where: b.id == ^id and b.epoch == ^epoch and b.state in [:pending, :active],
             select: {b, m.address}
           ),
           prefix: scope.prefix
         ) do
      {binding, address} -> {:ok, binding, %Inbox{id: id, address: address}}
      _ -> {:error, :inbox_unavailable}
    end
  rescue
    _ -> {:error, :self_host_unavailable}
  end

  def fetch_binding(_), do: {:error, :inbox_unavailable}

  @doc false
  def guard(ref, %Inbox{} = expected) do
    case fetch_binding(ref) do
      {:ok, _, ^expected} -> :ok
      _ -> {:error, :inbox_unavailable}
    end
  end

  @doc false
  def activate({id, _} = ref) do
    # A deliberate reconnect must publish its new checkpoint and clear this
    # marker in the caller's SAME transaction, via Ingestion.on_baseline.
    outer_transaction? = SelfHost.scope().repo.in_transaction?()

    case transaction(fn scope ->
           lock_mailbox(scope, id)

           case fetch_binding(ref) do
             {:ok, binding, _} ->
               if binding.reset_baseline and
                    (not outer_transaction? or
                       checkpoint_generation(scope, id) in [nil, binding.reset_generation]),
                  do: scope.repo.rollback(:baseline_activation_required)

               scope.repo.update!(
                 Ecto.Changeset.change(binding,
                   state: :active,
                   reset_baseline: false,
                   reset_generation: nil
                 ),
                 prefix: scope.prefix
               )

               :ok

             _ ->
               scope.repo.rollback(:inbox_unavailable)
           end
         end) do
      {:ok, :ok} -> :ok
      error -> error
    end
  end

  @doc false
  def token_data(content, options \\ [])

  def token_data(%Content{} = content, options) when is_list(options) do
    require_mail = Keyword.get(options, :require_mail_scope, true)
    valid_credential = if require_mail, do: &credential?/1, else: &retirable_credential?/1

    with true <- byte_size(Content.read(content)) <= 65_536,
         {:ok, token} when is_map(token) <- Jason.decode(Content.read(content)),
         true <-
           Enum.sort(Map.keys(token)) ==
             Enum.sort(~w(access_token refresh_token token_type expires_at scope)),
         true <- Enum.all?([token["access_token"], token["refresh_token"]], valid_credential),
         true <- token["token_type"] == "Bearer" and is_integer(token["expires_at"]),
         scope when is_binary(scope) <- token["scope"],
         true <- byte_size(scope) <= 4096,
         true <-
           not require_mail or
             "https://www.googleapis.com/auth/gmail.modify" in String.split(scope) do
      {:ok, token}
    else
      _ -> {:error, :invalid_google_credentials}
    end
  end

  def token_data(_, _), do: {:error, :invalid_google_credentials}

  defp subject?(value),
    do: is_binary(value) and byte_size(value) in 1..255 and Regex.match?(~r/\A[!-~]+\z/, value)

  defp credential?(value),
    do: is_binary(value) and byte_size(value) in 1..16_384 and Regex.match?(~r/\A[!-~]+\z/, value)

  defp retirable_credential?(value),
    do:
      is_binary(value) and byte_size(value) in 1..32_768 and String.valid?(value) and
        not String.contains?(value, ["\r", "\n", <<0>>])

  defp inbox_id(subject),
    do: "google-" <> Base.encode16(:crypto.hash(:sha256, subject), case: :lower)

  defp readdress_checkpoint!(scope, id, old_address, new_address) do
    alias EmailJanitor.Gmail.Ingestion.Checkpoint

    case scope.repo.get(Checkpoint, id, prefix: scope.prefix) do
      nil ->
        :ok

      %Checkpoint{address: ^old_address} = checkpoint ->
        scope.repo.update!(Ecto.Changeset.change(checkpoint, address: new_address),
          prefix: scope.prefix
        )

      _ ->
        scope.repo.rollback(:invalid_connection)
    end
  end

  defp checkpoint_generation(scope, id) do
    case scope.repo.get(EmailJanitor.Gmail.Ingestion.Checkpoint, id, prefix: scope.prefix) do
      nil -> nil
      checkpoint -> checkpoint.generation
    end
  end

  defp retire_replaced_subjects(scope, subject, address) do
    bindings =
      scope.repo.all(
        from(b in Binding,
          join: m in Mailbox,
          on: m.id == b.id,
          where:
            m.address == ^address and b.google_subject != ^subject and
              b.state in [:pending, :active, :reauthorization_required],
          order_by: b.id,
          select: b
        ),
        prefix: scope.prefix
      )

    for binding <- bindings do
      lock_mailbox(scope, binding.id)
      state = Revocations.stage!(scope, binding)

      scope.repo.update!(
        Ecto.Changeset.change(binding,
          state: state,
          reset_baseline: true,
          reset_generation: checkpoint_generation(scope, binding.id),
          token_ciphertext: nil,
          epoch: binding.epoch + 1,
          token_version: binding.token_version + 1
        ),
        prefix: scope.prefix
      )

      scope.repo.update_all(
        from(m in Mailbox, where: m.id == ^binding.id),
        [inc: [instruction_version: 1], set: [updated_at: DateTime.utc_now()]],
        prefix: scope.prefix
      )
    end
  end

  @doc false
  def lock_mailbox(scope, id) do
    scope.repo.one(from(m in Mailbox, where: m.id == ^id, lock: "FOR UPDATE"),
      prefix: scope.prefix
    ) ||
      scope.repo.rollback(:inbox_unavailable)
  end

  @doc false
  def transaction(fun) do
    scope = SelfHost.scope()
    scope.repo.transaction(fn -> fun.(scope) end)
  rescue
    _ -> {:error, :self_host_unavailable}
  end
end
