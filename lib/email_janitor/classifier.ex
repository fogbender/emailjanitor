defmodule EmailJanitor.Classifier do
  @moduledoc "A text-only model boundary that discards raw errors and validates all model output."
  alias EmailJanitor.Decision

  @callback classify(list(EmailJanitor.Message.t()), String.t(), keyword()) ::
              {:ok, String.t() | map()} | {:error, term()}

  def propose({adapter, options}, messages, instructions) do
    case adapter.classify(messages, instructions, options) do
      {:ok, result} ->
        case Decision.parse(result) do
          {:ok, decision} -> {:ok, decision}
          _ -> {:error, :invalid_decision}
        end

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
