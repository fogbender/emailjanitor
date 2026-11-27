defmodule EmailJanitor.Conversation do
  @moduledoc "Shared authenticated chat/email workflow. Hosts supply the scope, inbox, policy and connection guard."
  alias EmailJanitor.{Content, Executor, Owner, Preferences, Store}

  alias EmailJanitor.Conversation.{
    Context,
    Evidence,
    ExplicitSelection,
    Instructions,
    Ledger,
    Lookup,
    Outcome,
    Plan,
    Receipt
  }

  @doc "Handle one transient user message. The caller must authenticate it before constructing Context."
  def respond(%Context{} = ctx, request_id, %Content{} = request) do
    if ctx.scope.repo.in_transaction?() do
      {:error, :conversation_unavailable}
    else
      case Owner.workflow(fn -> respond_owned(ctx, request_id, request) end) do
        {:error, :executor_unavailable} -> {:error, :conversation_unavailable}
        result -> result
      end
    end
  rescue
    _ -> {:error, :conversation_unavailable}
  catch
    _, _ -> {:error, :conversation_unavailable}
  end

  defp respond_owned(ctx, request_id, request) do
    with {:ok, request_id} <- Ecto.UUID.cast(request_id),
         {:ok, _} <- Ecto.UUID.cast(ctx.conversation_id),
         true <- not ctx.scope.repo.in_transaction?(),
         true <- byte_size(Content.read(request)) in 1..16_000,
         {:ok, _} <- Evidence.decode(ctx.request_evidence),
         true <-
           is_nil(ctx.previous_request_id) or
             match?({:ok, _}, Ecto.UUID.cast(ctx.previous_request_id)),
         :ok <- ctx.guard.(),
         {:ok, snapshot} <- Preferences.snapshot(ctx.scope, ctx.inbox.id) do
      case Ledger.get(ctx.scope, ctx.inbox.id, ctx.conversation_id, request_id) do
        %Receipt{completed: true} = receipt ->
          {:ok, Outcome.render(receipt, snapshot)}

        %Receipt{} = receipt ->
          resume(ctx, receipt, snapshot)

        nil ->
          plan(ctx, request_id, request, snapshot, nil)
      end
    else
      _ -> {:error, :conversation_unavailable}
    end
  rescue
    _ -> {:error, :conversation_unavailable}
  catch
    _, _ -> {:error, :conversation_unavailable}
  end

  defp plan(ctx, request_id, request, snapshot, pending) do
    previous =
      if ctx.previous_request_id,
        do: Ledger.get(ctx.scope, ctx.inbox.id, ctx.conversation_id, ctx.previous_request_id),
        else: Ledger.latest(ctx.scope, ctx.inbox.id, ctx.conversation_id, request_id)

    ctx = %{
      ctx
      | prior_receipt: previous,
        model: Keyword.put(ctx.model, :previous_effects, previous_effects(previous))
    }

    evidence =
      case pending || previous do
        nil ->
          {:ok, [], [], false}

        receipt ->
          case Lookup.load(ctx, receipt.context_references) do
            {:ok, refs, messages} -> {:ok, refs, messages, not receipt.search_complete}
            _ when is_nil(pending) -> {:ok, [], [], false}
            error -> error
          end
      end

    with {:ok, refs, messages, truncated} <- evidence do
      propose(ctx, request_id, request, snapshot, refs, messages, truncated, 2)
    end
  end

  defp propose(ctx, request_id, request, snapshot, refs, messages, truncated, remaining) do
    with :ok <- ctx.guard.(),
         {:ok, proposal} <-
           ctx.planner.plan(
             ctx.inbox,
             snapshot,
             request,
             refs,
             messages,
             ctx.model
             |> Keyword.put(:search_truncated, truncated)
             |> Keyword.put(:request_evidence, ctx.request_evidence)
           ) do
      case proposal do
        %Plan{operation: :search} when remaining > 0 ->
          with {:ok, refs, messages, truncated} <- Lookup.search(ctx, proposal.query) do
            propose(ctx, request_id, request, snapshot, refs, messages, truncated, remaining - 1)
          end

        %Plan{operation: :search} ->
          {:ok,
           Content.new(
             "Please narrow down the sender or subject so I can identify the right email."
           )}

        %Plan{} = proposal ->
          apply_plan(ctx, request_id, snapshot, proposal, refs)
      end
    else
      _ -> {:error, :conversation_unavailable}
    end
  end

  defp apply_plan(ctx, request_id, snapshot, proposal, refs) do
    selected =
      if proposal.operation == :answer,
        do: refs,
        else: Enum.filter(refs, &(&1.token in proposal.references))

    with {:ok, receipt} <-
           Ledger.reserve(
             ctx.scope,
             ctx.inbox.id,
             ctx.conversation_id,
             request_id,
             proposal,
             selected,
             fn -> admit_plan(ctx, request_id, proposal.operation, selected) end
           ) do
      if receipt.completed do
        {:ok, Outcome.render(receipt, snapshot)}
      else
        with :ok <- teach(ctx, receipt, proposal, snapshot) do
          finish_effects(ctx, receipt, selected, proposal)
        end
      end
    end
  end

  defp resume(ctx, receipt, snapshot) do
    with {:ok, claimed} <- claim_receipt(ctx, receipt) do
      if claimed.completed do
        {:ok, Outcome.render(claimed, snapshot)}
      else
        with {:ok, claimed} <- recover_preference(ctx, claimed),
             do: resume_effects(ctx, claimed)
      end
    end
  end

  defp claim_receipt(ctx, receipt) do
    refs = receipt_refs(ctx, receipt)

    Ledger.reserve(
      ctx.scope,
      ctx.inbox.id,
      ctx.conversation_id,
      receipt.id,
      %Plan{
        operation: receipt.operation,
        references: Enum.map(refs, & &1.token),
        preference_target: receipt.preference_target,
        search_complete: receipt.search_complete
      },
      refs,
      ctx.guard
    )
  end

  # A dead workflow may have committed the instruction before recording its
  # metadata result. Recover only that durable proof; never replan a pinned
  # selection or persist the original request/instruction proposal for retry.
  defp recover_preference(ctx, %{preference_status: :pending} = receipt) do
    expected_key = if receipt.preference_target == :all, do: "all", else: "inbox:" <> ctx.inbox.id

    change =
      ctx.scope.repo.get(Preferences.Change, receipt.id,
        prefix: ctx.scope.prefix,
        log: false,
        telemetry_event: nil
      )

    {status, revision} =
      case change do
        %Preferences.Change{target_key: ^expected_key, revision: revision, changed: changed} ->
          {if(changed, do: :updated, else: :unchanged), revision}

        _ ->
          {:failed, nil}
      end

    Ledger.record_preference(
      ctx.scope,
      ctx.inbox.id,
      ctx.conversation_id,
      receipt.id,
      status,
      revision
    )
  end

  defp recover_preference(_, receipt), do: {:ok, receipt}

  defp resume_effects(ctx, receipt) do
    unfinished = unprocessed(receipt, receipt_refs(ctx, receipt))

    loaded =
      Enum.reduce_while(unfinished, {:ok, [], [], []}, fn ref, {:ok, fresh, missing, known} ->
        case bound_result(ctx, receipt, ref) do
          {status, action_id} when status in [:done, :unresolved] ->
            {:cont, {:ok, fresh, missing, known ++ [{ref, status, action_id}]}}

          :none ->
            case Lookup.load(ctx, [%{message_id: ref.message_id, thread_id: ref.thread_id}]) do
              {:ok, [value], _} ->
                {:cont, {:ok, fresh ++ [%{value | action_id: ref.action_id}], missing, known}}

              {:error, :reference_not_found} ->
                {:cont, {:ok, fresh, missing ++ [ref], known}}

              _ ->
                {:halt, {:error, :conversation_unavailable}}
            end

          _ ->
            {:halt, {:error, :conversation_unavailable}}
        end
      end)

    with {:ok, fresh, missing, known} <- loaded do
      refs =
        Enum.map(receipt_refs(ctx, receipt), fn ref ->
          Enum.find(fresh, &(&1.token == ref.token)) || ref
        end)

      proposal = %Plan{
        operation: receipt.operation,
        references: Enum.map(refs, & &1.token),
        preference_target: receipt.preference_target,
        instruction: Content.new(""),
        replace_instructions: [],
        query: Content.new(""),
        reply: Content.new(""),
        search_complete: receipt.search_complete
      }

      with {:ok, claimed} <-
             Ledger.reserve(
               ctx.scope,
               ctx.inbox.id,
               ctx.conversation_id,
               receipt.id,
               proposal,
               refs,
               ctx.guard
             ),
           :ok <- record_results(ctx, claimed, missing, "missing", nil),
           :ok <- record_known(ctx, claimed, known) do
        excluded =
          Enum.map(missing, & &1.token) ++ Enum.map(known, fn {ref, _, _} -> ref.token end)

        available = Enum.reject(refs, &(&1.token in excluded))
        finish_effects(ctx, claimed, available, proposal)
      end
    end
  end

  defp bound_result(ctx, receipt, ref) do
    case Ledger.action_result(ctx.scope, ctx.inbox.id, receipt.id, ref.message_id) do
      {:prepared, action_id} ->
        # Durable recovery and host settlement never send a Gmail request.
        # Recovery cannot cancel an owner whose death is not proven.
        Executor.recover(ctx.scope, ctx.inbox, action_id, execution_options(ctx))

        case Ledger.action_result(ctx.scope, ctx.inbox.id, receipt.id, ref.message_id) do
          {:prepared, _} -> {:error, :request_in_flight}
          result -> result
        end

      result ->
        result
    end
  end

  defp record_known(ctx, receipt, known) do
    Enum.reduce_while(known, :ok, fn {ref, status, action_id}, :ok ->
      case record_results(ctx, receipt, [ref], Atom.to_string(status), action_id) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp receipt_refs(ctx, receipt) do
    Enum.map(receipt.references, fn metadata ->
      {:ok, ref} =
        EmailJanitor.Conversation.Reference.new(
          ctx.inbox.id,
          metadata["message_id"],
          metadata["thread_id"],
          "",
          "",
          action_id: metadata["action_id"]
        )

      ref
    end)
  end

  defp finish_effects(ctx, receipt, refs, proposal) do
    with {:ok, current} <- Preferences.snapshot(ctx.scope, ctx.inbox.id),
         :ok <- effects(ctx, receipt, refs, current),
         {:ok, finished} <-
           Ledger.complete(ctx.scope, ctx.inbox.id, ctx.conversation_id, receipt.id) do
      if proposal.operation == :answer and proposal.preference_target == :none and
           Content.read(proposal.reply) != "",
         do: {:ok, read_only_reply(ctx, proposal, current)},
         else: {:ok, Outcome.render(finished, current)}
    end
  end

  # Free prose cannot certify an earlier ambiguous Gmail request. For that turn
  # report only durable facts; the user can ask their next question separately.
  defp read_only_reply(%{prior_receipt: %Receipt{} = prior}, proposal, snapshot) do
    uncertain =
      (not prior.completed and prior.operation != :answer) or
        prior.preference_status in [:pending, :failed] or
        Enum.any?(prior.results, &(&1["status"] in ["unresolved", "unavailable"]))

    if uncertain, do: Outcome.render(prior, snapshot), else: proposal.reply
  end

  defp read_only_reply(_, proposal, _), do: proposal.reply

  defp teach(_ctx, %{preference_target: :none}, _plan, _snapshot), do: :ok

  defp teach(_ctx, %{preference_status: status}, _plan, _snapshot)
       when status in [:updated, :unchanged],
       do: :ok

  defp teach(ctx, receipt, proposal, snapshot) do
    target = if proposal.preference_target == :all, do: :all, else: {:inbox, ctx.inbox.id}

    current = if proposal.preference_target == :all, do: snapshot.global, else: snapshot.local

    changed =
      with {:ok, instruction} <-
             Instructions.edit(current, proposal.replace_instructions, proposal.instruction),
           do: Preferences.replace(ctx.scope, target, snapshot, instruction, receipt.id)

    {status, revision} =
      case changed do
        {:ok, change} -> {if(change.changed, do: :updated, else: :unchanged), change.revision}
        _ -> {:failed, nil}
      end

    with {:ok, _} <-
           Ledger.record_preference(
             ctx.scope,
             ctx.inbox.id,
             ctx.conversation_id,
             receipt.id,
             status,
             revision
           ),
         do: :ok
  end

  defp effects(_ctx, %{operation: :answer}, _refs, _snapshot), do: :ok

  defp effects(ctx, %{operation: :done} = receipt, refs, snapshot) do
    refs
    |> Enum.group_by(& &1.thread_id)
    |> Enum.reduce_while(:ok, fn {thread_id, selected}, :ok ->
      remaining = unprocessed(receipt, selected)

      if remaining == [] do
        {:cont, :ok}
      else
        ids = Enum.map(remaining, & &1.message_id)

        result =
          with {:ok, opts} <- cleanup_options(ctx, receipt, remaining, ids),
               :ok <- ctx.guard.(),
               {:ok, proposal} <-
                 Executor.review(
                   ctx.scope,
                   ctx.inbox,
                   thread_id,
                   ctx.gmail,
                   {ExplicitSelection, []},
                   Content.read(Preferences.text(snapshot)),
                   snapshot.instruction_version,
                   opts
                 ),
               :ok <- ctx.guard.() do
            Executor.execute(ctx.scope, ctx.inbox, proposal, ctx.gmail, opts)
          end

        case record_cleanup(ctx, receipt, remaining, result) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end
    end)
  end

  defp effects(ctx, %{operation: :restore} = receipt, refs, snapshot) do
    refs
    |> Enum.group_by(& &1.action_id)
    |> Enum.reduce_while(:ok, fn {action_id, selected}, :ok ->
      remaining = unprocessed(receipt, selected)

      {status, id} =
        cond do
          remaining == [] ->
            {"unchanged", nil}

          is_nil(action_id) ->
            {"unsupported", nil}

          true ->
            effect_id = effect_id(receipt.id, action_id)
            restore = Keyword.get(ctx.execution_options, :restore_adapter, EmailJanitor.Restore)

            opts =
              execution_options(ctx)
              |> Keyword.put(:authorize, ctx.guard)
              |> Keyword.put(:expected_instruction_version, snapshot.instruction_version)

            result =
              try do
                with true <-
                       Code.ensure_loaded?(restore) and function_exported?(restore, :apply, 7),
                     :ok <- ctx.guard.() do
                  apply(restore, :apply, [
                    ctx.scope,
                    ctx.inbox,
                    effect_id,
                    action_id,
                    Enum.map(remaining, & &1.message_id),
                    ctx.gmail,
                    opts
                  ])
                else
                  false -> {:error, :restore_unsupported}
                  _ -> {:error, :restore_unavailable}
                end
              rescue
                _ -> {:unresolved, effect_id}
              catch
                _, _ -> {:unresolved, effect_id}
              end

            restore_result(ctx, restore, effect_id, result)
        end

      case record_results(ctx, receipt, remaining, status, id) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp unprocessed(receipt, refs) do
    terminal =
      Enum.filter(receipt.results, &(&1["status"] != "unavailable"))
      |> Enum.map(& &1["reference"])

    Enum.reject(refs, &(&1.token in terminal))
  end

  defp cleanup_result(ctx, {:deferred, _covering_id, result}), do: cleanup_result(ctx, result)
  defp cleanup_result(_ctx, {:done, id}), do: {"done", id}
  defp cleanup_result(_ctx, {:settlement_pending, id, :done}), do: {"done", id}
  defp cleanup_result(_ctx, {:settlement_pending, id, :unresolved}), do: {"unresolved", id}
  defp cleanup_result(_ctx, {:blocked, :upgrade_required}), do: {"blocked", nil}

  defp cleanup_result(_ctx, {:blocked, reason})
       when reason in [:manually_restored, :action_settled],
       do: {"protected", nil}

  defp cleanup_result(_ctx, {:unresolved, id}), do: {"unresolved", id}
  defp cleanup_result(_ctx, {:existing, id, :done}), do: {"done", id}
  defp cleanup_result(_ctx, {:existing, _id, :restored}), do: {"protected", nil}

  defp cleanup_result(_ctx, {:existing, id, state}) when state in [:intent, :unresolved],
    do: {"unresolved", id}

  defp cleanup_result(_ctx, {:keep, :no_matching_inbox_messages}), do: {"unchanged", nil}
  defp cleanup_result(_ctx, {:keep, _}), do: {"protected", nil}

  defp cleanup_result(_ctx, {:skip, reason}) when reason != :proposal_changed,
    do: {"protected", nil}

  defp cleanup_result(_ctx, _), do: {"unavailable", nil}

  defp record_cleanup(ctx, receipt, refs, result) do
    {status, effect_id} = cleanup_result(ctx, result)
    action = if effect_id, do: Store.get(ctx.scope, ctx.inbox.id, effect_id), else: nil

    Enum.reduce_while(refs, :ok, fn ref, :ok ->
      actual =
        case Ledger.action_result(ctx.scope, ctx.inbox.id, receipt.id, ref.message_id) do
          {known, id} when known in [:done, :unresolved] ->
            {Atom.to_string(known), id}

          {:prepared, _} ->
            {"unavailable", nil}

          :none ->
            cond do
              ((status == "done" and action) && ref.message_id not in action.message_ids) and
                  Ledger.owns_action?(ctx.scope, ctx.inbox.id, receipt.id, action.id) ->
                {"unchanged", nil}

              status == "done" ->
                {"protected", nil}

              (status == "unresolved" and action) && action.state == :unresolved ->
                {"protected", nil}

              status == "unresolved" ->
                {"unavailable", nil}

              true ->
                {status, effect_id}
            end
        end

      {actual_status, actual_id} = actual

      case record_results(ctx, receipt, [ref], actual_status, actual_id) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp restore_result({:done, id}), do: {"restored", id}
  defp restore_result({:existing, :done, id}), do: {"restored", id}
  defp restore_result({:unresolved, id}), do: {"unresolved", id}

  defp restore_result({:existing, :unresolved, id}), do: {"unresolved", id}
  defp restore_result({:existing, :intent, _}), do: {"unavailable", nil}

  defp restore_result({:existing, :cancelled, _}), do: {"unsupported", nil}
  defp restore_result({:error, :restore_pending}), do: {"protected", nil}

  defp restore_result({:error, reason})
       when reason in [
              :invalid_restore_selection,
              :effect_conflict,
              :unconfirmed_suppression,
              :restore_unsupported,
              :unconfirmed_restoration,
              :wrong_inbox
            ],
       do: {"unsupported", nil}

  defp restore_result(_), do: {"unavailable", nil}

  defp restore_result(ctx, restore, effect_id, {:error, reason} = result)
       when reason not in [
              :invalid_restore_selection,
              :effect_conflict,
              :unconfirmed_suppression,
              :restore_unsupported,
              :unconfirmed_restoration,
              :wrong_inbox,
              :restore_pending
            ] do
    if Code.ensure_loaded?(restore) and function_exported?(restore, :outcome, 3) do
      case apply(restore, :outcome, [ctx.scope, ctx.inbox, effect_id]) do
        {:done, ^effect_id} -> {"restored", effect_id}
        {:cancelled, ^effect_id} -> {"unsupported", nil}
        {:unresolved, ^effect_id} -> {"unresolved", effect_id}
        _ -> restore_result(result)
      end
    else
      restore_result(result)
    end
  rescue
    _ -> {"unavailable", nil}
  catch
    _, _ -> {"unavailable", nil}
  end

  defp restore_result(_, _, _, result), do: restore_result(result)

  defp record_results(ctx, receipt, refs, status, effect_id) do
    Enum.reduce_while(refs, :ok, fn ref, :ok ->
      case Ledger.record_result(
             ctx.scope,
             ctx.inbox.id,
             ctx.conversation_id,
             receipt.id,
             ref.token,
             status,
             effect_id
           ) do
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp execution_options(ctx),
    do:
      ctx.execution_options |> Keyword.put(:policy, ctx.policy) |> Keyword.put(:guard, ctx.guard)

  defp admit_plan(ctx, request_id, operation, refs) do
    with :ok <- ctx.guard.() do
      case Keyword.get(ctx.execution_options, :on_plan_admitted) do
        nil -> :ok
        callback when is_function(callback, 3) -> callback.(request_id, operation, refs)
        _ -> {:error, :invalid_plan_hook}
      end
    end
  end

  defp cleanup_options(ctx, receipt, refs, ids) do
    policy =
      case Keyword.get(ctx.execution_options, :policy_for_references) do
        nil -> ctx.policy
        factory when is_function(factory, 1) -> factory.(refs)
      end

    case policy do
      %EmailJanitor.Policy{} ->
        {:ok,
         execution_options(ctx)
         |> Keyword.put(
           :policy,
           EmailJanitor.Conversation.ExecutionPolicy.new(policy, ctx.scope, ctx.inbox.id, receipt)
         )
         |> Keyword.put(:cleanup_target_ids, ids)}

      _ ->
        {:error, :policy_unavailable}
    end
  rescue
    _ -> {:error, :policy_unavailable}
  catch
    _, _ -> {:error, :policy_unavailable}
  end

  defp previous_effects(nil), do: nil

  defp previous_effects(receipt) do
    %{
      "operation" => Atom.to_string(receipt.operation),
      "preference_scope" => Atom.to_string(receipt.preference_target),
      "preference_status" => Atom.to_string(receipt.preference_status),
      "completed" => receipt.completed,
      "results" => Enum.map(receipt.results, &Map.take(&1, ["reference", "status"]))
    }
  end

  defp effect_id(request_id, action_id) do
    <<a::48, _::4, b::12, _::2, c::62, _::binary>> =
      :crypto.hash(:sha256, request_id <> action_id)

    {:ok, uuid} = Ecto.UUID.load(<<a::48, 5::4, b::12, 2::2, c::62>>)
    uuid
  end
end
