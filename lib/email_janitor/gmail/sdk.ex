defmodule EmailJanitor.Gmail.SDK do
  @moduledoc """
  Google-generated Gmail SDK adapter. Every operation binds a token to the
  configured mailbox using getProfile before reading or mutating mail.

  Options: `config: EmailJanitor.Gmail.Config`. Token refresh belongs to the host.
  All SDK failures collapse into fixed categories; raw SDK envelopes never escape.
  """
  @behaviour EmailJanitor.Gmail
  alias EmailJanitor.{Address, Content}
  alias EmailJanitor.Gmail.{Config, Parser}
  alias GoogleApi.Gmail.V1.{Api.Users, Connection, Model}

  @impl true
  def thread(inbox_id, thread_id, opts) do
    guarded(fn ->
      with true <- Parser.valid_id?(thread_id),
           {:ok, connection, _} <- verified(inbox_id, opts),
           {:ok, %Model.Thread{id: ^thread_id, messages: messages}} <-
             call(fn ->
               Users.gmail_users_threads_get(connection, "me", thread_id, format: "full")
             end),
           true <- is_list(messages) and length(messages) <= 200,
           {:ok, converted} <- convert_messages(messages),
           true <- Enum.all?(converted, &(&1.thread_id == thread_id)) do
        {:ok, converted}
      else
        {:error, _} = error -> error
        _ -> {:error, :invalid_thread}
      end
    end)
  end

  @impl true
  def history_id(inbox_id, opts) do
    guarded(fn ->
      with {:ok, _, %Model.Profile{historyId: id}} <- verified(inbox_id, opts),
           true <- history_id?(id),
           do: {:ok, id}
    end)
  end

  @doc "Resolve an arrival's thread ID using only minimal metadata, without downloading its body."
  def thread_id(inbox_id, message_id, opts) do
    guarded(fn ->
      with true <- Parser.valid_id?(message_id),
           {:ok, connection, _} <- verified(inbox_id, opts),
           {:ok, %Model.Message{id: ^message_id, threadId: thread_id}} <-
             call(fn ->
               Users.gmail_users_messages_get(connection, "me", message_id,
                 format: "minimal",
                 fields: "id,threadId"
               )
             end),
           true <- Parser.valid_id?(thread_id) do
        {:ok, thread_id}
      else
        {:error, _} = error -> error
        _ -> {:error, :invalid_message_reference}
      end
    end)
  end

  @doc """
  Register or renew Gmail notifications for a pre-provisioned Pub/Sub topic.
  Watch all changes so restoration/SENT/DRAFT changes are not filtered out.
  The returned watch cursor is a registration snapshot; renewal must not advance
  the host's durable processed-history cursor or skip pending catch-up.
  """
  def watch(inbox_id, topic, opts) do
    guarded(fn ->
      with true <-
             is_binary(topic) and
               Regex.match?(
                 ~r/\Aprojects\/[a-z][a-z0-9-]{4,28}[a-z0-9]\/topics\/[A-Za-z][A-Za-z0-9_.~+%-]{2,254}\z/,
                 topic
               ),
           {:ok, connection, _} <- verified(inbox_id, opts),
           {:ok, %Model.WatchResponse{historyId: id, expiration: expiry}} <-
             call(fn ->
               Users.gmail_users_watch(connection, "me",
                 body: %Model.WatchRequest{topicName: topic}
               )
             end),
           true <- history_id?(id),
           {:ok, expires_at} <- watch_expiration(expiry) do
        {:ok, %{history_id: id, expires_at: expires_at}}
      else
        {:error, _} = error -> error
        _ -> {:error, :invalid_watch}
      end
    end)
  end

  @doc "Gmail uses the same watch endpoint to renew; preserve the existing processing cursor."
  def renew_watch(inbox_id, topic, opts), do: watch(inbox_id, topic, opts)

  @doc "Stop this OAuth application's mailbox watch before deliberately disconnecting an inbox."
  def stop_watch(inbox_id, opts) do
    guarded(fn ->
      with {:ok, connection, _} <- verified(inbox_id, opts),
           {:ok, _} <- call(fn -> Users.gmail_users_stop(connection, "me") end),
           do: :ok
    end)
  end

  @impl true
  def contacted(inbox_id, keys, opts) do
    guarded(fn ->
      with true <- is_list(keys) and length(keys) <= 200,
           {:ok, normalized} <- normalize_keys(keys),
           {:ok, connection, _} <- verified(inbox_id, opts) do
        config = Keyword.fetch!(opts, :config)

        Enum.reduce_while(normalized, {:ok, MapSet.new()}, fn key, {:ok, found} ->
          case correspondence(connection, key, config.max_pages, nil, MapSet.new()) do
            {:ok, true} -> {:cont, {:ok, MapSet.put(found, key)}}
            {:ok, false} -> {:cont, {:ok, found}}
            error -> {:halt, error}
          end
        end)
      else
        {:error, _} = error -> error
        _ -> {:error, :invalid_contact_keys}
      end
    end)
  end

  @impl true
  def remove_inbox(inbox_id, ids, opts) do
    guarded(fn ->
      with {:ok, dispatch} <- prepare_remove_inbox(inbox_id, ids, opts), do: dispatch.()
    end)
  end

  @doc """
  Verify/freeze credentials, mailbox and exact IDs before the durable dispatch marker.
  The returned transient closure sends only batchModify with a 15-second default
  transport budget. Never persist the closure or inspect its captured environment.
  """
  def prepare_remove_inbox(inbox_id, ids, opts) do
    guarded(fn ->
      with true <-
             is_list(ids) and length(ids) in 1..1000 and Enum.all?(ids, &Parser.valid_id?/1),
           true <- length(Enum.uniq(ids)) == length(ids),
           {:ok, connection, _} <- verified(inbox_id, opts) do
        config = Keyword.fetch!(opts, :config)

        prepared =
          Tesla.client(Tesla.Client.middleware(connection), Config.mutation_transport(config))

        {:ok, fn -> dispatch_remove(prepared, ids) end}
      else
        {:error, _} = error -> error
        _ -> {:error, :invalid_message_ids}
      end
    end)
  end

  defp dispatch_remove(connection, ids) do
    guarded(fn ->
      with :ok <- EmailJanitor.TransportPrivacy.check(),
           {:ok, _} <-
             call(fn ->
               Users.gmail_users_messages_batch_modify(connection, "me",
                 body: %Model.BatchModifyMessagesRequest{ids: ids, removeLabelIds: ["INBOX"]}
               )
             end) do
        :ok
      else
        {:error, :unsafe_http_observers} -> {:error, :gmail_unavailable}
        {:error, _} = error -> error
        _ -> {:error, :gmail_unavailable}
      end
    end)
  end

  @doc "Fetch complete paginated history, or explicitly return incomplete evidence."
  def history(inbox_id, start_id, opts) do
    guarded(fn ->
      with true <- history_id?(start_id),
           {:ok, connection, _} <- verified(inbox_id, opts) do
        config = Keyword.fetch!(opts, :config)
        # Recovery can require evidence fetched after a dead-owner barrier.
        # Capture once, before the first history request, not after the last page.
        started_at = DateTime.utc_now()

        case history_pages(connection, start_id, config.max_pages, nil, MapSet.new(), [], [], []) do
          {:ok, evidence} -> {:ok, Map.put(evidence, :started_at, started_at)}
          error -> error
        end
      else
        {:error, _} = error -> error
        _ -> {:error, :invalid_history_id}
      end
    end)
  end

  defp verified(inbox_id, opts) do
    %Config{inbox: inbox, token_resolver: resolver} = config = Keyword.fetch!(opts, :config)

    with true <- inbox_id == inbox.id,
         :ok <- EmailJanitor.TransportPrivacy.check(),
         {:ok, token} <- resolver.(),
         {:ok, token} <- token(token),
         connection = Connection.new(token),
         connection =
           Tesla.client(
             [EmailJanitor.Gmail.BoundedResponse | Tesla.Client.middleware(connection)],
             Config.transport(config)
           ),
         {:ok, %Model.Profile{emailAddress: address} = profile} <-
           call(fn -> Users.gmail_users_get_profile(connection, "me") end),
         {:ok, normalized} <- Address.normalize(address),
         true <- normalized == inbox.address do
      {:ok, connection, profile}
    else
      false ->
        {:error, :wrong_inbox}

      {:error, reason}
      when reason in [:authorization_required, :forbidden, :rate_limited, :not_found] ->
        {:error, reason}

      _ ->
        {:error, :gmail_unavailable}
    end
  end

  defp token(%Content{} = token), do: token(Content.read(token))

  defp token(token) when is_binary(token) do
    if byte_size(token) in 1..16_384 and not String.contains?(token, ["\r", "\n", <<0>>]),
      do: {:ok, token},
      else: {:error, :invalid_token}
  end

  defp token(_), do: {:error, :invalid_token}

  defp convert_messages(messages) do
    Enum.reduce_while(messages, {:ok, []}, fn value, {:ok, acc} ->
      case Parser.message(value) do
        {:ok, message} -> {:cont, {:ok, [message | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, messages} -> {:ok, Enum.reverse(messages)}
      error -> error
    end
  end

  defp normalize_keys(keys) do
    Enum.reduce_while(keys, {:ok, []}, fn key, {:ok, acc} ->
      value = if is_binary(key) and String.contains?(key, "@"), do: key, else: "contact@#{key}"

      case Address.normalize(value) do
        {:ok, address} ->
          normalized = if String.contains?(key, "@"), do: address, else: Address.domain(address)

          if not String.contains?(key, "@") and Address.shared?(normalized),
            do: {:halt, {:error, :invalid_contact_keys}},
            else: {:cont, {:ok, Enum.uniq([normalized | acc])}}

        _ ->
          {:halt, {:error, :invalid_contact_keys}}
      end
    end)
  end

  defp correspondence(_, _, 0, _, _), do: {:error, :correspondence_limit}

  defp correspondence(connection, key, remaining, page, seen) do
    # Quote normalized values and verify real To/Cc/Bcc metadata afterwards.
    # Gmail search alone can match a display name or another address substring.
    query = ~s({to:"#{key}" cc:"#{key}" bcc:"#{key}"})
    params = [labelIds: ["SENT"], includeSpamTrash: true, q: query, maxResults: 100]
    params = if page, do: Keyword.put(params, :pageToken, page), else: params

    with {:ok, %Model.ListMessagesResponse{} = response} <-
           call(fn -> Users.gmail_users_messages_list(connection, "me", params) end),
         {:ok, match?} <- verify_recipients(connection, response.messages || [], key) do
      cond do
        match? ->
          {:ok, true}

        response.nextPageToken in [nil, ""] ->
          {:ok, false}

        not is_binary(response.nextPageToken) or MapSet.member?(seen, response.nextPageToken) ->
          {:error, :correspondence_limit}

        true ->
          correspondence(
            connection,
            key,
            remaining - 1,
            response.nextPageToken,
            MapSet.put(seen, response.nextPageToken)
          )
      end
    end
  end

  defp verify_recipients(connection, messages, key) when is_list(messages) do
    Enum.reduce_while(messages, {:ok, false}, fn message, _ ->
      with true <- Parser.valid_id?(message.id),
           {:ok, %Model.Message{payload: %Model.MessagePart{headers: headers}}} <-
             call(fn ->
               Users.gmail_users_messages_get(connection, "me", message.id,
                 format: "metadata",
                 metadataHeaders: ["To", "Cc", "Bcc"]
               )
             end),
           {:ok, addresses} <- recipients(headers) do
        if Enum.any?(
             addresses,
             &if(String.contains?(key, "@"),
               do: key == &1,
               else: key in Address.contact_keys(&1)
             )
           ),
           do: {:halt, {:ok, true}},
           else: {:cont, {:ok, false}}
      else
        {:error, _} = error -> {:halt, error}
        _ -> {:halt, {:error, :invalid_correspondence}}
      end
    end)
  end

  defp recipients(headers) when is_list(headers) do
    headers
    |> Enum.filter(&(String.downcase(&1.name || "") in ["to", "cc", "bcc"]))
    |> Enum.reduce_while({:ok, []}, fn header, {:ok, acc} ->
      case Address.parse(header.value) do
        {:ok, values} -> {:cont, {:ok, acc ++ values}}
        _ -> {:halt, {:error, :invalid_correspondence}}
      end
    end)
    |> case do
      {:ok, []} -> {:error, :invalid_correspondence}
      other -> other
    end
  end

  defp history_pages(_, _, 0, _, _, _, _, _), do: incomplete(:page_limit)

  defp history_pages(connection, start, remaining, page, seen, events, added, deleted) do
    params = [startHistoryId: start, maxResults: 500]
    params = if page, do: Keyword.put(params, :pageToken, page), else: params

    case call(fn -> Users.gmail_users_history_list(connection, "me", params) end) do
      {:ok, %Model.ListHistoryResponse{} = response} ->
        with true <- history_id?(response.historyId),
             {:ok, chunk, new, gone} <- history_records(response.history || []) do
          events = events ++ chunk
          added = added ++ new
          deleted = deleted ++ gone

          cond do
            response.nextPageToken in [nil, ""] ->
              {:ok,
               %{
                 complete?: true,
                 history_id: response.historyId,
                 events: Enum.uniq(events) |> Enum.sort_by(&String.to_integer(&1.history_id)),
                 added_message_ids: Enum.uniq(added),
                 deleted_message_ids: Enum.uniq(deleted)
               }}

            not is_binary(response.nextPageToken) or MapSet.member?(seen, response.nextPageToken) ->
              incomplete(:page_loop)

            true ->
              history_pages(
                connection,
                start,
                remaining - 1,
                response.nextPageToken,
                MapSet.put(seen, response.nextPageToken),
                events,
                added,
                deleted
              )
          end
        else
          _ -> incomplete(:invalid_history)
        end

      {:error, :not_found} ->
        incomplete(:history_expired)

      _ ->
        incomplete(:gmail_unavailable)
    end
  end

  defp history_records(records) when is_list(records) do
    Enum.reduce_while(records, {:ok, [], [], []}, fn record, {:ok, acc, new, gone} ->
      with %Model.History{} <- record,
           true <- history_id?(record.id),
           {:ok, additions} <- changes(record.labelsAdded || [], record.id, :inbox_added),
           {:ok, removals} <- changes(record.labelsRemoved || [], record.id, :inbox_removed),
           {:ok, added_ids} <- message_ids(record.messagesAdded || []),
           {:ok, deleted_ids} <- message_ids(record.messagesDeleted || []) do
        {:cont, {:ok, acc ++ additions ++ removals, new ++ added_ids, gone ++ deleted_ids}}
      else
        _ -> {:halt, {:error, :invalid_history}}
      end
    end)
  end

  defp history_records(_), do: {:error, :invalid_history}

  defp changes(values, history_id, event) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      with %{labelIds: labels, message: %Model.Message{id: message_id}} <- value,
           true <- is_list(labels) and Enum.all?(labels, &is_binary/1),
           true <- Parser.valid_id?(message_id) do
        if "INBOX" in labels,
          do:
            {:cont,
             {:ok, [%{history_id: history_id, message_id: message_id, event: event} | acc]}},
          else: {:cont, {:ok, acc}}
      else
        _ -> {:halt, {:error, :invalid_history}}
      end
    end)
  end

  defp changes(_, _, _), do: {:error, :invalid_history}

  defp message_ids(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      with %{message: %Model.Message{id: message_id}} <- value,
           true <- Parser.valid_id?(message_id) do
        {:cont, {:ok, [message_id | acc]}}
      else
        _ -> {:halt, {:error, :invalid_history}}
      end
    end)
  end

  defp message_ids(_), do: {:error, :invalid_history}

  defp incomplete(reason),
    do:
      {:ok,
       %{
         complete?: false,
         reason: reason,
         events: [],
         history_id: nil,
         added_message_ids: [],
         deleted_message_ids: []
       }}

  defp history_id?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9]{1,32}\z/, value)

  defp watch_expiration(value) when is_binary(value) do
    with {milliseconds, ""} when milliseconds > 0 <- Integer.parse(value),
         {:ok, expires_at} <- DateTime.from_unix(milliseconds, :millisecond) do
      {:ok, expires_at}
    else
      _ -> {:error, :invalid_watch}
    end
  end

  defp watch_expiration(_), do: {:error, :invalid_watch}

  defp call(fun) do
    case fun.() do
      {:ok, _} = result -> result
      {:error, %Tesla.Env{status: 401}} -> {:error, :authorization_required}
      {:error, %Tesla.Env{status: 403, body: body}} -> {:error, forbidden_reason(body)}
      {:error, %Tesla.Env{status: 404}} -> {:error, :not_found}
      {:error, %Tesla.Env{status: 429}} -> {:error, :rate_limited}
      _ -> {:error, :gmail_unavailable}
    end
  rescue
    _ -> {:error, :gmail_unavailable}
  catch
    _, _ -> {:error, :gmail_unavailable}
  end

  defp forbidden_reason(body) when is_binary(body) do
    with {:ok, %{"error" => %{"errors" => errors}}} <- Jason.decode(body),
         true <- is_list(errors),
         true <-
           Enum.any?(
             errors,
             &(is_map(&1) and
                 &1["reason"] in [
                   "rateLimitExceeded",
                   "userRateLimitExceeded",
                   "dailyLimitExceeded"
                 ])
           ) do
      :rate_limited
    else
      _ -> :forbidden
    end
  end

  defp forbidden_reason(_), do: :forbidden

  defp guarded(fun) do
    case fun.() do
      :ok -> :ok
      {:ok, _} = result -> result
      {:error, _} = error -> error
      _ -> {:error, :gmail_unavailable}
    end
  rescue
    _ -> {:error, :gmail_unavailable}
  catch
    _, _ -> {:error, :gmail_unavailable}
  end
end
