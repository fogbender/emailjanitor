defmodule EmailJanitor.Decision do
  @moduledoc "Validated, body-free classifier output. Model prose is never persisted."
  @enforce_keys [:action, :confidence, :category]
  defstruct [:action, :confidence, :category]

  @actions %{"keep" => :keep, "done" => :done}
  @confidence %{"high" => :high, "low" => :low}
  @categories %{
    "cold_outreach" => :cold_outreach,
    "legitimate" => :legitimate,
    "uncertain" => :uncertain,
    "user_instruction" => :user_instruction
  }

  def parse(json) when is_binary(json) and byte_size(json) <= 2048 do
    with {:ok, value} <- Jason.decode(json) do
      parse(value)
    else
      _ -> {:error, :invalid_decision}
    end
  rescue
    _ -> {:error, :invalid_decision}
  end

  def parse(value) when is_map(value) and map_size(value) == 3 do
    with {:ok, action} <- Map.fetch(@actions, value["action"]),
         {:ok, confidence} <- Map.fetch(@confidence, value["confidence"]),
         {:ok, category} <- Map.fetch(@categories, value["category"]),
         true <- action != :done or category in [:cold_outreach, :user_instruction] do
      {:ok, %__MODULE__{action: action, confidence: confidence, category: category}}
    else
      _ -> {:error, :invalid_decision}
    end
  end

  def parse(_), do: {:error, :invalid_decision}
end
