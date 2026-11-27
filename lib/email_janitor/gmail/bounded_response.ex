defmodule EmailJanitor.Gmail.BoundedResponse do
  @moduledoc """
  Supply the decompression cap required by current Tesla to Google's generated
  client, which still compiles DecompressResponse with an empty options list.

  Request generation, authentication middleware and response decoding remain
  owned by the SDK. Keep this compatibility boundary covered by transport tests
  until google_gax exposes this option directly.
  """
  @behaviour Tesla.Middleware
  @max_body_size 8 * 1024 * 1024

  @impl true
  def call(env, next, _opts) do
    bounded =
      Enum.map(next, fn
        {Tesla.Middleware.DecompressResponse, :call, [opts]} ->
          {Tesla.Middleware.DecompressResponse, :call,
           [Keyword.put(opts, :max_body_size, @max_body_size)]}

        entry ->
          entry
      end)

    case Tesla.run(env, bounded) do
      {:ok, %Tesla.Env{body: body}} when is_binary(body) and byte_size(body) > @max_body_size ->
        {:error, :response_too_large}

      result ->
        result
    end
  end
end
