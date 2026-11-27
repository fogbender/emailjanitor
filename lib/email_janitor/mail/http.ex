defmodule EmailJanitor.Mail.HTTP.TooLarge do
  @moduledoc false
  defexception message: "mail response exceeded limit"
end

defmodule EmailJanitor.Mail.HTTP do
  @moduledoc false
  @behaviour ExAws.Request.HttpClient
  @max_bytes 1_048_576

  @impl true
  def request(method, url, body, headers, opts) do
    # SDK signing/operations remain ExAws-owned. This boundary prevents its HTTP
    # error logger from inspecting exceptions, and bounds untrusted responses.
    request = [
      method: method,
      url: url,
      body: if(body in [nil, ""], do: nil, else: body),
      headers: [{"accept-encoding", "identity"} | headers],
      retry: false,
      redirect: false,
      decode_body: false,
      raw: true,
      compressed: false,
      receive_timeout: 25_000,
      connect_options: [timeout: 5_000],
      into: &collect/2
    ]

    request =
      if opts[:test_plug], do: Keyword.put(request, :plug, opts[:test_plug]), else: request

    case Req.request(request) do
      {:ok, %{body: body} = response} when is_binary(body) and byte_size(body) <= @max_bytes ->
        if opts[:format] != :raw and String.contains?(body, "<!DOCTYPE") do
          {:error, %{reason: :unsafe_mail_response}}
        else
          {:ok,
           %{status_code: response.status, headers: Req.get_headers_list(response), body: body}}
        end

      {:error, %__MODULE__.TooLarge{}} ->
        {:error, %{reason: :mail_response_too_large}}

      _ ->
        {:error, %{reason: :mail_http_unavailable}}
    end
  rescue
    __MODULE__.TooLarge -> {:error, %{reason: :mail_response_too_large}}
    _ -> {:error, %{reason: :mail_http_unavailable}}
  catch
    _, _ -> {:error, %{reason: :mail_http_unavailable}}
  end

  defp collect({:data, data}, {request, response}) do
    body = response.body || ""

    if byte_size(body) + byte_size(data) <= @max_bytes do
      {:cont, {request, %{response | body: body <> data}}}
    else
      # Raising is caught before either Req or ExAws can inspect this response.
      raise __MODULE__.TooLarge
    end
  end
end
