defmodule EmailJanitor.Conversation do
  @moduledoc "Shared authenticated chat/email workflow. Hosts supply the scope, inbox, policy and connection guard."
  alias EmailJanitor.{Content, Executor, Owner, Preferences, Store}

  alias EmailJanitor.Conversation.{
    Context,
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
      Owner.run(fn -> respond_owned(ctx, request_id, request) end)
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
         :ok <- ctx.guard.(),
         {:ok, snapshot} <- Preferences.snapshot(ctx.scope, ctx.inbox.id) do
      case Ledger.get(ctx.scope, ctx.inbox.id, ctx.conversation_id, request_id) do
        %Receipt{completed: true} = receipt ->
          {:ok, Outcome.render(receipt, snapshot)}

        %Receipt{preference_status: status} = receipt when status != :pending ->
          resume(ctx, receipt, snapshot)

        pending ->
          plan(ctx, request_id, request, snapshot, pending)
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
    previous = Ledger.latest(ctx.scope, ctx.inbox.id, ctx.conversation_id, request_id)
    ctx = %{ctx | model: Keyword.put(ctx.model, :previous_effects, previous_effects(previous))}

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
             Keyword.put(ctx.model, :search_truncated, truncated)
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

  defp resume(ctx, receipt, _snapshot) do
    with {:ok, refs, _messages} <- Lookup.load(ctx, receipt.references) do
      # Keep the original action binding even if a later cleanup now appears in
      # the lookup. Preference completion and exact effect selection are durable.
      refs =
        Enum.map(refs, fn ref ->
          original = Enum.find(receipt.references, &(&1["token"] == ref.token))
          %{ref | action_id: original["action_id"]}
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
             ) do
        finish_effects(ctx, claimed, refs, proposal)
      end
    end
  end

  defp finish_effects(ctx, receipt, refs, proposal) do
    with {:ok, current} <- Preferences.snapshot(ctx.scope, ctx.inbox.id),
         :ok <- effects(ctx, receipt, refs, current),
         {:ok, finished} <-
           Ledger.complete(ctx.scope, ctx.inbox.id, ctx.conversation_id, receipt.id) do
      if proposal.operation == :answer and proposal.preference_target == :none and
           Content.read(proposal.reply) != "",
         do: {:ok, proposal.reply},
         else: {:ok, Outcome.render(finished, current)}
    end
  end

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
          with {:ok, opts} <- cleanup_options(ctx, remaining, ids),
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
            {"unchanged", nil}

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
                  _ -> {:error, :restore_unavailable}
                end
              rescue
                _ -> {:unresolved, effect_id}
              catch
                _, _ -> {:unresolved, effect_id}
              end

            restore_result(result)
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

    if status == "done" do
      action = Store.get(ctx.scope, ctx.inbox.id, effect_id)

      Enum.reduce_while(refs, :ok, fn ref, :ok ->
        actual =
          if action && ref.message_id in action.applied_message_ids,
            do: "done",
            else: "unavailable"

        case record_results(ctx, receipt, [ref], actual, effect_id) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    else
      record_results(ctx, receipt, refs, status, effect_id)
    end
  end

  defp restore_result({:done, id}), do: {"restored", id}
  defp restore_result({:existing, :done, id}), do: {"restored", id}
  defp restore_result({:unresolved, id}), do: {"unresolved", id}

  defp restore_result({:existing, state, id}) when state in [:intent, :unresolved],
    do: {"unresolved", id}

  defp restore_result(_), do: {"unavailable", nil}

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

  defp cleanup_options(ctx, refs, ids) do
    policy =
      case Keyword.get(ctx.execution_options, :policy_for_references) do
        nil -> ctx.policy
        factory when is_function(factory, 1) -> factory.(refs)
      end

    case policy do
      %EmailJanitor.Policy{} ->
        {:ok,
         execution_options(ctx)
         |> Keyword.put(:policy, policy)
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
