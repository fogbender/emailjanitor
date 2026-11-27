defmodule EmailJanitor.Classifier do
  @moduledoc "A text-only model boundary that discards raw errors and validates all model output."
  alias EmailJanitor.{Decision, Inbox}

  @callback classify(list(EmailJanitor.Message.t()), String.t(), keyword()) ::
              {:ok, String.t() | map()} | {:keep, :unreadable_content} | {:error, term()}

  def propose({adapter, options}, messages, instructions, %Inbox{} = inbox) do
    options = Keyword.put(options, :inbox, inbox)

    case adapter.classify(messages, instructions, options) do
      {:ok, result} ->
        case Decision.parse(result) do
          {:ok, decision} -> {:ok, decision}
          _ -> {:error, :invalid_decision}
        end

      {:keep, :unreadable_content} = keep ->
        keep

      {:error, _} ->
        {:error, :model_unavailable}

      _ ->
        {:error, :invalid_decision}
    end
  rescue
    _ -> {:error, :model_unavailable}
  catch
    _, _ -> {:error, :model_unavailable}
  end
end
