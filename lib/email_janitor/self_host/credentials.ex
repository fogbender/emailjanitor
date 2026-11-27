defmodule EmailJanitor.SelfHost.Credentials do
  @moduledoc "Refresh only this explicit inbox's encrypted grant; never use a machine Google profile."
  import Ecto.Query
  alias EmailJanitor.{Content, Owner, SelfHost}
  alias EmailJanitor.Google.OAuth
  alias EmailJanitor.SelfHost.{Binding, Grants, Refreshes, Revocations, Store}
  alias EmailJanitor.Store.Mailbox

  def token(ref) do
    with {:ok, binding, _} <- Store.fetch_binding(ref),
         {:ok, content} <- SelfHost.open("gmail-token", binding.id, binding.token_ciphertext),
         {:ok, token} <- Store.token_data(content) do
      if token["expires_at"] >= System.system_time(:second) + 120 do
        {:ok, Content.new(token["access_token"])}
      else
        refresh(ref, binding, content)
      end
    else
      _ -> {:error, :google_credentials_unavailable}
    end
  rescue
    _ -> {:error, :google_credentials_unavailable}
  end

  defp refresh(ref, before, old) do
    # Persist ownership before wire, independently of publication/CAS. Disconnect
    # waits until every reply was captured or its owner is physically quarantined.
    result =
      Owner.run(
        fn ->
          case Refreshes.begin(ref, before) do
            {:ok, attempt} ->
              case OAuth.refresh(SelfHost.config().google_oauth, old) do
                {:ok, content} ->
                  publish(ref, before, content, attempt)

                {:error, :reauthorization_required} ->
                  retire(ref, before, attempt)

                _ ->
                  Refreshes.ambiguous(attempt)
                  {:error, :google_credentials_unavailable}
              end

            _ ->
              cached_token(ref)
          end
        end,
        40_000
      )

    case result do
      {:ok, %Content{}} -> result
      {:error, :reauthorization_required} -> result
      _ -> {:error, :google_credentials_unavailable}
    end
  end

  defp publish(ref, before, content, attempt) do
    with {:ok, token} <- Store.token_data(content, require_mail_scope: false),
         {:ok, cipher} <- SelfHost.seal("gmail-token", before.id, content),
         {:ok, :captured} <-
           Store.transaction(fn scope ->
             Store.lock_mailbox(scope, before.id)
             Grants.retain!(scope, before.id, content, cipher)
             Refreshes.complete!(scope, attempt)
             :captured
           end),
         {:ok, publication} <-
           Store.transaction(fn scope ->
             Store.lock_mailbox(scope, before.id)

             current = scope.repo.get!(Binding, before.id, prefix: scope.prefix, log: false)

             allowed =
               match?({:ok, _}, Store.token_data(content)) and
                 match?({:ok, _, _}, Store.fetch_binding(ref)) and
                 current.token_version == before.token_version and
                 token["expires_at"] >= System.system_time(:second) + 120

             if allowed, do: Grants.retain_cipher!(scope, before.id, current.token_ciphertext)

             if allowed do
               scope.repo.update!(
                 Ecto.Changeset.change(current,
                   token_ciphertext: cipher,
                   token_version: current.token_version + 1
                 ),
                 prefix: scope.prefix
               )

               :published
             else
               # A late rotation is still an owned capability, even after
               # disconnect. Never activate it or throw it away on a CAS miss.
               if current.state not in [:pending, :active] do
                 state =
                   Revocations.stage!(scope, %{current | token_ciphertext: nil}, new_grant: true)

                 scope.repo.update!(Ecto.Changeset.change(current, state: state),
                   prefix: scope.prefix,
                   log: false
                 )
               end

               :captured_stale
             end
           end) do
      if publication == :published,
        do: {:ok, Content.new(token["access_token"])},
        else: cached_token(ref)
    else
      {:error, :credentials_changed} -> cached_token(ref)
      _ -> {:error, :google_credentials_unavailable}
    end
  end

  defp retire(ref, before, attempt) do
    result =
      Store.transaction(fn scope ->
        Store.lock_mailbox(scope, before.id)
        Refreshes.complete!(scope, attempt)

        with {:ok, current, _} <- Store.fetch_binding(ref),
             true <- current.token_version == before.token_version do
          Grants.forget_cipher!(scope, before.id, current.token_ciphertext)

          scope.repo.update!(
            Ecto.Changeset.change(current,
              state: :reauthorization_required,
              token_ciphertext: nil,
              token_version: current.token_version + 1,
              epoch: current.epoch + 1
            ),
            prefix: scope.prefix
          )

          scope.repo.update_all(
            from(m in Mailbox, where: m.id == ^before.id),
            [inc: [instruction_version: 1], set: [updated_at: DateTime.utc_now()]],
            prefix: scope.prefix
          )

          :retired
        else
          _ -> :changed
        end
      end)

    case result do
      {:ok, :retired} -> {:error, :reauthorization_required}
      {:ok, :changed} -> cached_token(ref)
      _ -> {:error, :google_credentials_unavailable}
    end
  end

  defp cached_token(ref) do
    with {:ok, binding, _} <- Store.fetch_binding(ref),
         {:ok, content} <- SelfHost.open("gmail-token", binding.id, binding.token_ciphertext),
         {:ok, token} <- Store.token_data(content),
         true <- token["expires_at"] >= System.system_time(:second) + 120 do
      {:ok, Content.new(token["access_token"])}
    else
      _ -> {:error, :google_credentials_unavailable}
    end
  end
end
