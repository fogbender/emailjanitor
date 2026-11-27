defmodule EmailJanitor.Worker.Config do
  @moduledoc """
  Trusted host-owned per-inbox worker dependencies. No ambient active account.

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
  """
  alias EmailJanitor.{Inbox, Policy, Store.Scope}
  @enforce_keys [:scope, :inbox, :gmail, :classifier, :preferences, :authorize, :topic]
  @derive {Inspect, only: [:inbox]}
  defstruct @enforce_keys ++
              [
                policy: nil,
                report: nil,
                clock: nil,
                lifecycle: :resume,
                on_baseline: nil,
                allow_recheck: nil,
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
         report when is_function(report, 1) <- Keyword.get(opts, :report, fn _ -> :ok end),
         clock when is_function(clock, 0) <- Keyword.get(opts, :clock, &DateTime.utc_now/0),
         self_mail when is_function(self_mail, 1) <-
           Keyword.get(opts, :self_mail, fn _ -> {:ok, false} end),
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
         report: report,
         clock: clock,
         lifecycle: lifecycle,
         on_baseline: callback,
         allow_recheck: recheck,
         self_mail: self_mail
       }}
    else
      _ -> {:error, :invalid_worker_config}
    end
  end

  def new(_, _, _), do: {:error, :invalid_worker_config}
end
