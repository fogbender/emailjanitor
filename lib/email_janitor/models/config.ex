defmodule EmailJanitor.Models.Config do
  @moduledoc "Explicit host-controlled model configuration; credentials redact on inspection."
  alias EmailJanitor.Content
  @enforce_keys [:provider, :model, :api_key]
  @derive {Inspect, only: [:provider, :model, :deployment]}
  defstruct [:provider, :model, :api_key, :base_url, :deployment]

  def new(provider, model, api_key, opts \\ []) do
    with true <- provider in [:azure, :openai, :anthropic],
         true <- is_binary(model) and byte_size(model) in 1..100,
         true <- is_binary(api_key) and byte_size(api_key) > 0,
         :ok <- endpoint(provider, opts[:base_url]),
         true <-
           provider != :azure or
             (is_binary(opts[:deployment]) and byte_size(opts[:deployment]) > 0) do
      {:ok,
       %__MODULE__{
         provider: provider,
         model: model,
         api_key: Content.new(api_key),
         base_url: opts[:base_url],
         deployment: opts[:deployment]
       }}
    else
      _ -> {:error, :invalid_model_config}
    end
  end

  defp endpoint(:azure, nil), do: {:error, :missing_endpoint}
  defp endpoint(_, nil), do: :ok

  defp endpoint(_, endpoint) when is_binary(endpoint) do
    case URI.new(endpoint) do
      {:ok, %URI{scheme: "https", host: host, userinfo: nil, query: nil, fragment: nil}}
      when is_binary(host) and host != "" ->
        :ok

      _ ->
        {:error, :invalid_endpoint}
    end
  end

  defp endpoint(_, _), do: {:error, :invalid_endpoint}
end
