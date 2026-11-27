defmodule EmailJanitor.Conversation.ExplicitSelection do
  @moduledoc "Only an authenticated conversation's selected IDs reach this classifier; all executor safeguards still apply."
  @behaviour EmailJanitor.Classifier

  @impl true
  def classify(_messages, _instructions, opts) do
    case opts[:target_ids] do
      ids when is_list(ids) and length(ids) in 1..5 ->
        {:ok,
         %{
           "decisions" =>
             Enum.map(
               ids,
               &%{
                 "message_id" => &1,
                 "action" => "done",
                 "confidence" => "high",
                 "category" => "user_instruction"
               }
             )
         }}

      _ ->
        {:error, :invalid_selection}
    end
  end
end
