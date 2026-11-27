defmodule EmailJanitor.Policy do
  @moduledoc """
  Host-owned transactional admission and durable-result settlement; single-user
  default is unlimited. Callbacks execute on the scoped repo's connection
  inside an inbox/action lock transaction. Keep them bounded database operations,
  never provider/network calls. A settlement error rolls back its side effects;
  the already durable Gmail outcome remains available for a later retry.
  """
  @enforce_keys [:adapter, :context]
  @derive {Inspect, only: [:adapter]}
  defstruct [:adapter, :context]

  defmodule Admission do
    @moduledoc "Fresh full INBOX IDs, distinct from the selected Done mutation IDs."
    @enforce_keys [:inbox_message_ids]
    defstruct @enforce_keys
  end

  @callback reserve(term(), String.t(), String.t(), [String.t()], DateTime.t()) ::
              :ok | {:blocked, atom()} | {:error, atom()}
  @callback settle(term(), String.t(), String.t(), term()) :: :ok | {:error, atom()}
  @callback retire_candidate(term(), String.t(), String.t(), [String.t()]) ::
              :ok | {:error, atom()}
  @callback reserve(term(), String.t(), String.t(), [String.t()], DateTime.t(), %Admission{}) ::
              :ok | {:blocked, atom()} | {:error, atom()}
  @optional_callbacks reserve: 6

  def unlimited, do: %__MODULE__{adapter: EmailJanitor.Policy.Unlimited, context: nil}

  def reserve(%__MODULE__{} = policy, inbox_id, action_id, message_ids, now) do
    reserve(policy, inbox_id, action_id, message_ids, now, %Admission{
      inbox_message_ids: message_ids
    })
  end

  def reserve(
        %__MODULE__{} = policy,
        inbox_id,
        action_id,
        message_ids,
        now,
        %Admission{} = admission
      ) do
    Code.ensure_loaded?(policy.adapter)

    result =
      cond do
        function_exported?(policy.adapter, :reserve, 6) ->
          policy.adapter.reserve(policy.context, inbox_id, action_id, message_ids, now, admission)

        Enum.sort(message_ids) == Enum.sort(admission.inbox_message_ids) ->
          policy.adapter.reserve(policy.context, inbox_id, action_id, message_ids, now)

        true ->
          {:blocked, :partial_admission_unsupported}
      end

    case result do
      :ok -> :ok
      {:blocked, reason} when is_atom(reason) -> {:blocked, reason}
      _ -> {:error, :policy_unavailable}
    end
  rescue
    _ -> {:error, :policy_unavailable}
  catch
    _, _ -> {:error, :policy_unavailable}
  end

  def settle(%__MODULE__{} = policy, inbox_id, action_id, result) do
    case policy.adapter.settle(policy.context, inbox_id, action_id, result) do
      :ok -> :ok
      _ -> {:error, :policy_unavailable}
    end
  rescue
    _ -> {:error, :policy_unavailable}
  catch
    _, _ -> {:error, :policy_unavailable}
  end

  @doc """
  Retire superseded or freshly ineligible proposal metadata independently of
  Gmail/quota outcomes. This includes proven-unapplied cancelled actions whose
  work was superseded by fresh review. The callback must be idempotent.
  Retirement may precede host settlement of a cancelled action; remember the
  withdrawal across a later not-applied result without refunding quota here.
  """
  def retire_candidate(%__MODULE__{} = policy, inbox_id, candidate_id, message_ids) do
    case policy.adapter.retire_candidate(policy.context, inbox_id, candidate_id, message_ids) do
      :ok -> :ok
      _ -> {:error, :policy_unavailable}
    end
  rescue
    _ -> {:error, :policy_unavailable}
  catch
    _, _ -> {:error, :policy_unavailable}
  end
end

defmodule EmailJanitor.Policy.Unlimited do
  @moduledoc false
  @behaviour EmailJanitor.Policy
  def reserve(_, _, _, _, _), do: :ok
  def reserve(_, _, _, _, _, _), do: :ok
  def settle(_, _, _, _), do: :ok
  def retire_candidate(_, _, _, _), do: :ok
end
