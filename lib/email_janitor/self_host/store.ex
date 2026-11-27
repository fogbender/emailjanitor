defmodule EmailJanitor.SelfHost.Store do
  @moduledoc "Single immutable owner and encrypted Google connection bindings, without tenancy."
  import Ecto.Query
  alias EmailJanitor.{Address, Content, Digest, Inbox, SelfHost}
  alias EmailJanitor.Google.OAuth
  alias EmailJanitor.SelfHost.{Binding, Migration, Owner}
  alias EmailJanitor.Store.Mailbox

  def install(scope),
    do: Ecto.Migrator.up(scope.repo, 100, Migration, prefix: scope.prefix, log: false)

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

  def connect(subject, %OAuth.Result{} = result, timezone) do
    with true <- owner?(subject),
         true <- subject?(result.subject),
         {:ok, box} <- Inbox.new(inbox_id(result.subject), result.email),
         {:ok, _} <- Digest.Clock.local(DateTime.utc_now(), timezone),
         {:ok, token} <- token_data(result.token),
         true <- token["expires_at"] > System.system_time(:second),
         {:ok, cipher} <- SelfHost.seal("gmail-token", box.id, result.token) do
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
        retire_replaced_subjects(scope, result.subject, box.address)

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
        if readdressed and is_nil(binding), do: scope.repo.rollback(:invalid_connection)

        binding =
          binding ||
            %Binding{
              id: box.id,
              google_subject: result.subject,
              timezone: timezone,
              state: :pending
            }

        if binding.google_subject != result.subject, do: scope.repo.rollback(:invalid_connection)
        resumed = binding.state in [:pending, :active]

        if readdressed do
          scope.repo.update_all(
            from(m in Mailbox, where: m.id == ^box.id),
            [inc: [instruction_version: 1], set: [address: box.address, updated_at: now]],
            prefix: scope.prefix
          )
        end

        changes = %{
          timezone: timezone,
          token_ciphertext: cipher,
          token_version: binding.token_version + 1,
          state: if(resumed, do: binding.state, else: :pending),
          epoch: if(resumed and not readdressed, do: binding.epoch, else: binding.epoch + 1)
        }

        scope.repo.insert_or_update!(Ecto.Changeset.change(binding, changes),
          prefix: scope.prefix
        )

        :ok = Digest.configure(scope, box.id, timezone, now)
        box
      end)
    else
      false -> {:error, :unauthorized}
      _ -> {:error, :invalid_connection}
    end
  rescue
    _ -> {:error, :invalid_connection}
  end

  def connect(_, _, _), do: {:error, :invalid_connection}

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

               %Binding{state: :disconnected} ->
                 :ok

               binding ->
                 scope.repo.update!(
                   Ecto.Changeset.change(binding,
                     state: :disconnected,
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
           end) do
        {:ok, :ok} -> :ok
        error -> error
      end
    else
      {:error, :unauthorized}
    end
  end

  @doc false
  def token_data(%Content{} = content) do
    with true <- byte_size(Content.read(content)) <= 65_536,
         {:ok, token} when is_map(token) <- Jason.decode(Content.read(content)),
         true <-
           Enum.sort(Map.keys(token)) ==
             Enum.sort(~w(access_token refresh_token token_type expires_at scope)),
         true <- Enum.all?([token["access_token"], token["refresh_token"]], &credential?/1),
         true <- token["token_type"] == "Bearer" and is_integer(token["expires_at"]),
         scope when is_binary(scope) <- token["scope"],
         true <- byte_size(scope) <= 4096,
         true <- "https://www.googleapis.com/auth/gmail.modify" in String.split(scope) do
      {:ok, token}
    else
      _ -> {:error, :invalid_google_credentials}
    end
  end

  def token_data(_), do: {:error, :invalid_google_credentials}

  defp subject?(value),
    do: is_binary(value) and byte_size(value) in 1..255 and Regex.match?(~r/\A[!-~]+\z/, value)

  defp credential?(value),
    do: is_binary(value) and byte_size(value) in 1..16_384 and Regex.match?(~r/\A[!-~]+\z/, value)

  defp inbox_id(subject),
    do: "google-" <> Base.encode16(:crypto.hash(:sha256, subject), case: :lower)

  defp retire_replaced_subjects(scope, subject, address) do
    bindings =
      scope.repo.all(
        from(b in Binding,
          join: m in Mailbox,
          on: m.id == b.id,
          where:
            m.address == ^address and b.google_subject != ^subject and
              b.state in [:pending, :active],
          order_by: b.id,
          select: b
        ),
        prefix: scope.prefix
      )

    for binding <- bindings do
      lock_mailbox(scope, binding.id)

      scope.repo.update!(
        Ecto.Changeset.change(binding,
          state: :disconnected,
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
