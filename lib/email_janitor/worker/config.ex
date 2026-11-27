defmodule EmailJanitor.Worker.Config do
  @moduledoc """
  Trusted host-owned per-inbox worker dependencies. No ambient active account.

  `policy_for_messages` optionally derives {:ok, Policy} from fresh transient
  messages. Keep only needed ID/sender/subject metadata; do not retain bodies.
  The derived policy is used for Keep retirement, admission and settlement;
  durable recovery uses the base `policy` without fetching message content.
  `preferences` returns {:ok, redacted_instruction_content, mailbox_version}.
  `authorize` is bounded database-only work: it also runs inside policy admission.
  The host must bump that mailbox version atomically on disconnect/binding changes
  so Store.begin_dispatch invalidates work prepared before the change.
  `report` receives fixed metadata status atoms, never provider errors or content.
  `allow_recheck` returns :ok for currently paid/unlimited access, or
  {:blocked, :upgrade_required} to stop an unpaid queued request while retaining
  provenance. Transient errors leave that request retryable. The host requeues
  backlog after upgrade. `self_mail` verifies headers against scoped successful
  outgoing-mail evidence, never merely a sender/domain match.
  `allow_manual_recheck(authority_id, all_source_ids)` verifies every source ID
  against a host-owned authenticated grant, current Google identity and current
  paid/unlimited access; it runs before reading bodies and inside admission.
  It defaults to failure and must never infer authority from core candidates.
  """
  alias EmailJanitor.{Inbox, Policy, Store.Scope}
  @enforce_keys [:scope, :inbox, :gmail, :classifier, :preferences, :authorize, :topic]
  @derive {Inspect, only: [:inbox]}
  defstruct @enforce_keys ++
              [
                policy: nil,
                policy_for_messages: nil,
                report: nil,
                clock: nil,
                lifecycle: :resume,
                on_baseline: nil,
                allow_recheck: nil,
                allow_manual_recheck: nil,
                self_mail: nil
              ]

  def new(%Scope{} = scope, %Inbox{} = inbox, opts) when is_list(opts) do
    with {gmail, gmail_options} when is_atom(gmail) and is_list(gmail_options) <- opts[:gmail],
         {classifier, model_options} when is_atom(classifier) and is_list(model_options) <-
           opts[:classifier],
         preferences when is_function(preferences, 0) <- opts[:preferences],
         authorize when is_function(authorize, 0) <- opts[:authorize],
         topic when is_binary(topic) and byte_size(topic) in 1..512 <- opts[:topic],
         %Policy{} = policy <- Keyword.get(opts, :policy, Policy.unlimited()),
         factory = Keyword.get(opts, :policy_for_messages),
         true <- is_nil(factory) or is_function(factory, 1),
         report when is_function(report, 1) <- Keyword.get(opts, :report, fn _ -> :ok end),
         clock when is_function(clock, 0) <- Keyword.get(opts, :clock, &DateTime.utc_now/0),
         self_mail when is_function(self_mail, 1) <-
           Keyword.get(opts, :self_mail, fn _ -> {:ok, false} end),
         manual when is_function(manual, 2) <-
           Keyword.get(opts, :allow_manual_recheck, fn _, _ ->
             {:error, :manual_recheck_unsupported}
           end),
         recheck when is_function(recheck, 1) <-
           Keyword.get(opts, :allow_recheck, fn _ -> :ok end),
         callback when is_function(callback, 1) <-
           Keyword.get(opts, :on_baseline, fn _ -> :ok end),
         lifecycle <- Keyword.get(opts, :lifecycle, :resume),
         true <-
           lifecycle == :resume or match?({:reconnect, value} when is_binary(value), lifecycle) do
      {:ok,
       %__MODULE__{
         scope: scope,
         inbox: inbox,
         gmail: {gmail, gmail_options},
         classifier: {classifier, model_options},
         preferences: preferences,
         authorize: authorize,
         topic: topic,
         policy: policy,
         policy_for_messages: factory,
         report: report,
         clock: clock,
         lifecycle: lifecycle,
         on_baseline: callback,
         allow_recheck: recheck,
         allow_manual_recheck: manual,
         self_mail: self_mail
       }}
    else
      _ -> {:error, :invalid_worker_config}
    end
  end

  def new(_, _, _), do: {:error, :invalid_worker_config}

  @doc "Derive a transient host policy from already fetched messages, without altering other capabilities."
  def with_message_policy(config, messages) do
    case config.policy_for_messages do
      nil ->
        {:ok, config}

      factory ->
        case factory.(messages) do
          {:ok, %Policy{} = policy} -> {:ok, %{config | policy: policy}}
          _ -> {:error, :policy_unavailable}
        end
    end
  rescue
    _ -> {:error, :policy_unavailable}
  catch
    _, _ -> {:error, :policy_unavailable}
  end

  @doc false
  def recheck(config, %{source_kind: :manual, authority_id: authority, message_ids: ids}) do
    case config.allow_manual_recheck.(authority, ids) do
      :ok ->
        :ok

      {:blocked, :upgrade_required} = blocked ->
        blocked

      {:error, reason} = error
      when reason in [:policy_unavailable, :connection_changed, :manual_recheck_unsupported] ->
        error

      _ ->
        {:error, :manual_authorization_changed}
    end
  rescue
    _ -> {:error, :policy_unavailable}
  catch
    _, _ -> {:error, :policy_unavailable}
  end

  def recheck(config, source), do: config.allow_recheck.(source.candidate_id)
end
