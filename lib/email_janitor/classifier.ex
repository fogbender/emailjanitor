defmodule EmailJanitor.Classifier do
  @moduledoc "A text-only model boundary that discards raw errors and validates all model output."
  alias EmailJanitor.{Decision, Inbox, Message, TargetDecisions}

  @callback classify(list(EmailJanitor.Message.t()), String.t(), keyword()) ::
              {:ok, String.t() | map()}
              | {:keep, :unreadable_content}
              | {:invalid, :decision}
              | {:error, term()}

  def propose({adapter, options}, messages, instructions, %Inbox{} = inbox) do
    call(adapter, options, messages, instructions, inbox, &Decision.parse/1)
  end

  def propose_targets({adapter, options}, messages, instructions, %Inbox{} = inbox) do
    ids = messages |> Enum.filter(&Message.cleanup_target?/1) |> Enum.map(& &1.id) |> Enum.sort()
    options = Keyword.put(options, :target_ids, ids)
    call(adapter, options, messages, instructions, inbox, &TargetDecisions.parse(&1, ids))
  end

  defp call(adapter, options, messages, instructions, inbox, parse) do
    options = Keyword.put(options, :inbox, inbox)

    case adapter.classify(messages, instructions, options) do
      {:ok, result} ->
        case parse.(result) do
          {:ok, decision} -> {:ok, decision}
          _ -> {:error, :invalid_decision}
        end

      {:keep, :unreadable_content} = keep ->
        keep

      {:error, :model_rejected} ->
        {:error, :model_rejected}

      {:error, _} ->
        {:error, :model_unavailable}

      {:invalid, :decision} ->
        {:error, :invalid_decision}

      _ ->
        {:error, :invalid_decision}
    end
  rescue
    _ -> {:error, :model_unavailable}
  catch
    _, _ -> {:error, :model_unavailable}
  end
end
