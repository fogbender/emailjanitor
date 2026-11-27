defmodule EmailJanitor.SelfHost.Credentials do
  @moduledoc "Refresh only this explicit inbox's encrypted grant; never use a machine Google profile."
  import Ecto.Query
  alias EmailJanitor.{Content, SelfHost}
  alias EmailJanitor.Google.OAuth
  alias EmailJanitor.SelfHost.Store
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
    # Provider calls and encryption happen outside the short publication lock.
    # A disconnected/reconsented binding cannot be overwritten by a late refresh.
    case OAuth.refresh(SelfHost.config().google_oauth, old) do
      {:ok, content} -> publish(ref, before, content)
      {:error, :reauthorization_required} -> retire(ref, before)
      _ -> {:error, :google_credentials_unavailable}
    end
  end

  defp publish(ref, before, content) do
    with {:ok, token} <- Store.token_data(content),
         true <- token["expires_at"] >= System.system_time(:second) + 120,
         {:ok, cipher} <- SelfHost.seal("gmail-token", before.id, content),
         {:ok, :ok} <-
           Store.transaction(fn scope ->
             Store.lock_mailbox(scope, before.id)

             with {:ok, current, _} <- Store.fetch_binding(ref),
                  true <- current.token_version == before.token_version do
               scope.repo.update!(
                 Ecto.Changeset.change(current,
                   token_ciphertext: cipher,
                   token_version: current.token_version + 1
                 ),
                 prefix: scope.prefix
               )

               :ok
             else
               _ -> scope.repo.rollback(:credentials_changed)
             end
           end) do
      {:ok, Content.new(token["access_token"])}
    else
      _ -> {:error, :google_credentials_unavailable}
    end
  end

  defp retire(ref, before) do
    Store.transaction(fn scope ->
      Store.lock_mailbox(scope, before.id)

      with {:ok, current, _} <- Store.fetch_binding(ref),
           true <- current.token_version == before.token_version do
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
      end
    end)

    {:error, :reauthorization_required}
  end
end
