defmodule EmailJanitor.Models.Config do
  @moduledoc "Two deployment paths: AWS Bedrock for self-hosting, Azure AI for the hosted service."
  alias EmailJanitor.Content
  @enforce_keys [:provider, :model]
  @derive {Inspect, only: [:provider, :model, :deployment, :region]}
  defstruct [:provider, :model, :api_key, :base_url, :deployment, :region]

  def new(provider, model, api_key \\ nil, opts \\ []) do
    with true <- provider in [:azure, :bedrock],
         true <-
           is_binary(model) and Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9._:-]{0,127}\z/, model),
         :ok <- validate(provider, api_key, opts) do
      {:ok,
       %__MODULE__{
         provider: provider,
         model: model,
         api_key: if(api_key, do: Content.new(api_key)),
         base_url: opts[:base_url],
         deployment: opts[:deployment],
         region: opts[:region]
       }}
    else
      _ -> {:error, :invalid_model_config}
    end
  end

  defp validate(:bedrock, nil, opts) do
    if opts[:region] == "us-east-1" and is_nil(opts[:base_url]),
      do: :ok,
      else: {:error, :invalid_aws_config}
  end

  defp validate(:azure, api_key, opts) when is_binary(api_key) and byte_size(api_key) > 0 do
    with deployment when is_binary(deployment) <- opts[:deployment],
         true <- Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_-]{0,63}\z/, deployment),
         endpoint when is_binary(endpoint) <- opts[:base_url],
         {:ok, %URI{scheme: "https", host: host, userinfo: nil, query: nil, fragment: nil}} <-
           URI.new(endpoint),
         true <- is_binary(host) and host != "" do
      :ok
    else
      _ -> {:error, :invalid_endpoint}
    end
  end

  defp validate(_, _, _), do: {:error, :invalid_model_config}
end
