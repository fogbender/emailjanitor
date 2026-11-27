defmodule EmailJanitor.Mail.Credentials do
  @moduledoc "Optional single-host EC2 role resolver. SaaS hosts supply their own short-lived credential-file resolver instead."

  def instance_role(region) do
    config =
      ExAws.Config.new(:sts,
        region: region,
        access_key_id: :instance_role,
        secret_access_key: :instance_role,
        security_token: :instance_role,
        require_imds_v2: true
      )

    with key when is_binary(key) and key != "" <- config[:access_key_id],
         secret when is_binary(secret) and secret != "" <- config[:secret_access_key],
         token when is_binary(token) and token != "" <- config[:security_token] do
      {:ok, [access_key_id: key, secret_access_key: secret, security_token: token]}
    else
      _ -> {:error, :mail_credentials_unavailable}
    end
  rescue
    _ -> {:error, :mail_credentials_unavailable}
  catch
    _, _ -> {:error, :mail_credentials_unavailable}
  end
end
