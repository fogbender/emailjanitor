defmodule EmailJanitor.Models.AWSRole do
  @moduledoc "Use ExAws's cached, rotating EC2 instance-role credentials; never shared developer profiles."
  def fetch(region) do
    config =
      ExAws.Config.new(:sts,
        region: region,
        access_key_id: :instance_role,
        secret_access_key: :instance_role,
        security_token: :instance_role
      )

    with key when is_binary(key) and key != "" <- config[:access_key_id],
         secret when is_binary(secret) and secret != "" <- config[:secret_access_key],
         token when is_binary(token) and token != "" <- config[:security_token] do
      {:ok, [region: region, access_key_id: key, secret_access_key: secret, session_token: token]}
    else
      _ -> {:error, :aws_credentials_unavailable}
    end
  rescue
    _ -> {:error, :aws_credentials_unavailable}
  catch
    _, _ -> {:error, :aws_credentials_unavailable}
  end
end
