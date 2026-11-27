defmodule EmailJanitor.Mail.Config do
  @moduledoc "Host-owned transport configuration; credentials are resolved afresh, never inherited from developer profiles."
  alias EmailJanitor.Address
  @enforce_keys [:region, :sender, :bucket, :queue_url, :topic_arn, :credentials]
  defstruct [:region, :sender, :bucket, :queue_url, :topic_arn, :credentials, :test_plug]

  def new(opts) do
    with {:ok, sender} <- Address.normalize(opts[:sender]),
         region when is_binary(region) <- opts[:region],
         true <- Regex.match?(~r/\A[a-z]{2}-[a-z]+-[0-9]\z/, region),
         bucket when is_binary(bucket) <- opts[:bucket],
         true <- Regex.match?(~r/\A[a-z0-9][a-z0-9-]{1,61}[a-z0-9]\z/, bucket),
         queue when is_binary(queue) <- opts[:queue_url],
         %URI{scheme: "https", host: host, path: path, query: nil, userinfo: nil} <-
           URI.parse(queue),
         true <- host == "sqs.#{region}.amazonaws.com",
         true <- Regex.match?(~r/\A\/[0-9]{12}\/[A-Za-z0-9_-]{1,80}\z/, path),
         topic when is_binary(topic) <- opts[:topic_arn],
         [_, account] <- Regex.run(~r/\A\/([0-9]{12})\//, path),
         true <-
           Regex.match?(
             ~r/\Aarn:aws:sns:#{Regex.escape(region)}:#{account}:[A-Za-z0-9_-]{1,256}\z/,
             topic
           ),
         credentials when is_function(credentials, 0) <- opts[:credentials] do
      {:ok, struct!(__MODULE__, Keyword.put(opts, :sender, sender))}
    else
      _ -> {:error, :invalid_mail_configuration}
    end
  rescue
    _ -> {:error, :invalid_mail_configuration}
  end

  defimpl Inspect do
    def inspect(_, _), do: "#EmailJanitor.Mail.Config<[REDACTED]>"
  end
end
