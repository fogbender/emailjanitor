defmodule EmailJanitor.GmailSDKTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  import EmailJanitor.Fixtures, only: [inbox: 0]
  alias EmailJanitor.{Content, Reconciliation}
  alias EmailJanitor.Gmail.{Config, Parser, SDK}
  alias EmailJanitor.Store.Action

  defp options(opts \\ []) do
    {:ok, config} =
      Config.new(
        inbox(),
        fn -> {:ok, Content.new("TOKEN_SENTINEL")} end,
        [adapter: Tesla.Mock] ++ opts
      )

    [config: config]
  end

  defp mock(fun, profile \\ %{"emailAddress" => "owner@acme.com", "historyId" => "100"}) do
    Tesla.Mock.mock(fn env ->
      assert {"authorization", "Bearer TOKEN_SENTINEL"} in env.headers
      assert String.starts_with?(env.url, "https://gmail.googleapis.com/")
      if String.ends_with?(env.url, "/profile"), do: Tesla.Mock.json(profile), else: fun.(env)
    end)
  end

  defp part(type, body, extras \\ %{}) do
    Map.merge(
      %{
        "mimeType" => type,
        "filename" => "",
        "body" => %{"data" => Base.url_encode64(body, padding: false)}
      },
      extras
    )
  end

  defp gmail_message(payload \\ part("text/plain", "PRIVATE_BODY_SENTINEL")) do
    Map.merge(
      %{
        "id" => "message-1",
        "threadId" => "thread-1",
        "internalDate" => "1795708800000",
        "labelIds" => ["INBOX", "UNREAD", "IMPORTANT"]
      },
      %{
        "payload" =>
          Map.put(payload, "headers", [
            %{"name" => "From", "value" => "sales@vendor.com"},
            %{"name" => "Subject", "value" => "Synthetic sales pitch"}
          ])
      }
    )
  end

  defp sent_metadata(address, header \\ "To") do
    %{"id" => "sent-1", "payload" => %{"headers" => [%{"name" => header, "value" => address}]}}
  end

  test "generated SDK authenticates and parses a full Gmail thread into transient content" do
    mock(fn env ->
      assert env.method == :get
      assert String.ends_with?(env.url, "/threads/thread-1")
      assert env.query[:format] == "full"
      Tesla.Mock.json(%{"id" => "thread-1", "messages" => [gmail_message()]})
    end)

    assert {:ok, [message]} = SDK.thread("inbox-1", "thread-1", options())
    assert message.id == "message-1"
    assert message.labels == ["INBOX", "UNREAD", "IMPORTANT"]
    assert Content.read(message.body) == "PRIVATE_BODY_SENTINEL"
    assert DateTime.compare(message.received_at, ~U[2026-11-26 16:00:00Z]) == :eq
    refute inspect(message) =~ "PRIVATE_BODY_SENTINEL"
  end

  test "configured inbox ID mismatch never resolves tokens or contacts Google" do
    resolver = fn -> flunk("wrong inbox must not resolve credentials") end
    {:ok, config} = Config.new(inbox(), resolver, adapter: Tesla.Mock)
    assert {:error, :wrong_inbox} = SDK.thread("another-inbox", "thread-1", config: config)
  end

  test "preparing a mutation freezes its verified token and exact IDs before dispatch" do
    owner = self()

    {:ok, config} =
      Config.new(
        inbox(),
        fn ->
          send(owner, :resolved_token)
          {:ok, Content.new("TOKEN_SENTINEL")}
        end,
        adapter: Tesla.Mock
      )

    Tesla.Mock.mock(fn env ->
      assert {"authorization", "Bearer TOKEN_SENTINEL"} in env.headers

      if String.ends_with?(env.url, "/profile") do
        send(owner, :profile_verified)
        Tesla.Mock.json(%{"emailAddress" => "owner@acme.com", "historyId" => "100"})
      else
        send(owner, :batch_sent)
        assert Jason.decode!(env.body) == %{"ids" => ["message-1"], "removeLabelIds" => ["INBOX"]}
        %Tesla.Env{status: 204, body: ""}
      end
    end)

    assert {:ok, dispatch} = SDK.prepare_remove_inbox("inbox-1", ["message-1"], config: config)
    assert is_function(dispatch, 0)
    refute inspect(dispatch) =~ "TOKEN_SENTINEL"
    assert_received :resolved_token
    assert_received :profile_verified
    refute_received :batch_sent
    assert :ok = dispatch.()
    assert_received :batch_sent
    refute_received :resolved_token
    refute_received :profile_verified
  end

  test "default prepared mutation leaves watchdog headroom and keeps TLS verification" do
    {:ok, config} = Config.new(inbox(), fn -> {:ok, "token"} end)
    assert {Tesla.Adapter.Httpc, options} = Config.mutation_transport(config)
    assert options[:timeout] + options[:connect_timeout] <= 15_000
    assert options[:ssl][:verify] == :verify_peer
  end

  test "OAuth token for a different account cannot read or modify a mailbox" do
    mock(
      fn _ -> flunk("wrong identity must not reach mailbox API") end,
      %{"emailAddress" => "other@acme.com", "historyId" => "100"}
    )

    assert {:error, :wrong_inbox} = SDK.thread("inbox-1", "thread-1", options())
    assert {:error, :wrong_inbox} = SDK.remove_inbox("inbox-1", ["message-1"], options())
  end

  test "mutation sends only exact message IDs and removes INBOX, preserving all other labels" do
    mock(fn env ->
      assert env.method == :post
      assert String.ends_with?(env.url, "/messages/batchModify")

      assert Jason.decode!(env.body) == %{
               "ids" => ["message-1", "message-2"],
               "removeLabelIds" => ["INBOX"]
             }

      %Tesla.Env{status: 204, body: ""}
    end)

    assert :ok = SDK.remove_inbox("inbox-1", ["message-1", "message-2"], options())
  end

  test "empty, duplicate, oversized and invalid ID batches never contact Google" do
    Tesla.Mock.mock(fn _ -> flunk("invalid IDs cannot reach Google") end)

    for ids <- [[], ["one", "one"], ["../thread"], Enum.map(1..1001, &Integer.to_string/1)] do
      assert {:error, :invalid_message_ids} = SDK.remove_inbox("inbox-1", ids, options())
    end
  end

  test "history cursor comes from the verified account's profile" do
    mock(fn _ -> flunk("profile is sufficient") end)
    assert {:ok, "100"} = SDK.history_id("inbox-1", options())
  end

  test "thread revision snapshot uses only metadata and changes with the provider revision" do
    snapshots =
      for revision <- ["100", "101"] do
        mock(fn env ->
          assert env.method == :get
          assert String.ends_with?(env.url, "/threads/thread-1")
          assert env.query[:format] == "minimal"
          assert env.query[:fields] == "id,historyId"
          Tesla.Mock.json(%{"id" => "thread-1", "historyId" => revision})
        end)

        assert {:ok, snapshot} = SDK.thread_snapshot("inbox-1", "thread-1", options())
        assert snapshot.thread_id == "thread-1" and byte_size(snapshot.fingerprint) == 64
        refute inspect(snapshot) =~ "TOKEN_SENTINEL"
        snapshot
      end

    assert hd(snapshots).fingerprint != List.last(snapshots).fingerprint
  end

  test "thread snapshots reject mismatched IDs, absent or invalid history and wrong account" do
    for body <- [
          %{"id" => "other", "historyId" => "100"},
          %{"id" => "thread-1"},
          %{"id" => "thread-1", "historyId" => "invalid"}
        ] do
      mock(fn _ -> Tesla.Mock.json(body) end)

      assert {:error, :invalid_thread_snapshot} =
               SDK.thread_snapshot("inbox-1", "thread-1", options())
    end

    mock(
      fn _ -> flunk("wrong identity must not reach thread metadata") end,
      %{"emailAddress" => "other@acme.com", "historyId" => "100"}
    )

    assert {:error, :wrong_inbox} = SDK.thread_snapshot("inbox-1", "thread-1", options())
  end

  test "arrival lookup requests only ID and thread ID metadata" do
    mock(fn env ->
      assert env.method == :get
      assert String.ends_with?(env.url, "/messages/message-1")
      assert env.query[:format] == "minimal"
      assert env.query[:fields] == "id,threadId"
      Tesla.Mock.json(%{"id" => "message-1", "threadId" => "thread-1"})
    end)

    assert {:ok, "thread-1"} = SDK.thread_id("inbox-1", "message-1", options())
  end

  test "arrival lookup rejects a mismatched returned message and missing thread ID" do
    for response <- [%{"id" => "other-message", "threadId" => "thread-1"}, %{"id" => "message-1"}] do
      mock(fn _ -> Tesla.Mock.json(response) end)

      assert {:error, :invalid_message_reference} =
               SDK.thread_id("inbox-1", "message-1", options())
    end
  end

  test "watch registration and renewal use a configured topic and retain all label events" do
    expiry = DateTime.add(DateTime.utc_now(), 6, :day) |> DateTime.to_unix(:millisecond)

    mock(fn env ->
      assert env.method == :post
      assert String.ends_with?(env.url, "/watch")

      assert Jason.decode!(env.body) == %{
               "topicName" => "projects/emailjanitor-test/topics/mailbox-changes"
             }

      Tesla.Mock.json(%{"historyId" => "200", "expiration" => Integer.to_string(expiry)})
    end)

    for method <- [:watch, :renew_watch] do
      assert {:ok, %{history_id: "200", expires_at: expires_at}} =
               apply(SDK, method, [
                 "inbox-1",
                 "projects/emailjanitor-test/topics/mailbox-changes",
                 options()
               ])

      assert DateTime.to_unix(expires_at, :millisecond) == expiry
    end
  end

  test "watch rejects malformed topic names before contacting Google" do
    Tesla.Mock.mock(fn _ -> flunk("invalid topic must not contact Google") end)

    for topic <- [
          nil,
          "mailbox-changes",
          "projects/../../topics/anything",
          "projects/emailjanitor-test/topics/name?secret=x"
        ] do
      assert {:error, :invalid_watch} = SDK.watch("inbox-1", topic, options())
    end
  end

  test "watch responses require a valid history cursor and expiration" do
    for response <- [
          %{"historyId" => "not-a-cursor", "expiration" => "1795708800000"},
          %{"historyId" => "200", "expiration" => "not-an-expiration"},
          %{"historyId" => "200", "expiration" => "100000000000000000000"},
          %{"historyId" => "200"}
        ] do
      mock(fn _ -> Tesla.Mock.json(response) end)

      assert {:error, :invalid_watch} =
               SDK.watch(
                 "inbox-1",
                 "projects/emailjanitor-test/topics/mailbox-changes",
                 options()
               )
    end
  end

  test "stopping a watch is verified and does not mutate email labels" do
    mock(fn env ->
      assert env.method == :post
      assert String.ends_with?(env.url, "/stop")
      assert env.body == ""
      %Tesla.Env{status: 204, body: ""}
    end)

    assert :ok = SDK.stop_watch("inbox-1", options())
  end

  test "MIME alternatives yield readable HTML pitch and links while attachments stay unfetched" do
    payload = %{
      "mimeType" => "multipart/mixed",
      "parts" => [
        %{
          "mimeType" => "multipart/alternative",
          "parts" => [
            part("text/plain", "Plain introduction"),
            part(
              "text/html",
              "<style>decoration</style><p>Development services</p><a href='https://vendor.com/book'>Book call</a>"
            )
          ]
        },
        part("text/plain", "ATTACHMENT_SENTINEL", %{"filename" => "private.txt"}),
        %{
          "mimeType" => "application/pdf",
          "filename" => "proposal.pdf",
          "body" => %{"attachmentId" => "never-fetch"}
        }
      ]
    }

    mock(fn env ->
      assert String.ends_with?(env.url, "/threads/thread-1")
      Tesla.Mock.json(%{"id" => "thread-1", "messages" => [gmail_message(payload)]})
    end)

    assert {:ok, [message]} = SDK.thread("inbox-1", "thread-1", options())
    text = Content.read(message.body)
    assert text =~ "Plain introduction"
    assert text =~ "Development services"
    assert text =~ "https://vendor.com/book"
    refute text =~ "decoration"
    refute text =~ "ATTACHMENT_SENTINEL"
    assert EmailJanitor.Message.header(message, "content-type") == "text/plain"
  end

  test "malformed MIME is a fixed failure rather than partial classification input" do
    mock(fn _ ->
      bad =
        gmail_message(%{
          "mimeType" => "text/plain",
          "body" => %{"data" => "%%%%PRIVATE_BODY_SENTINEL"}
        })

      Tesla.Mock.json(%{"id" => "thread-1", "messages" => [bad]})
    end)

    logs =
      capture_log(fn ->
        assert {:error, :invalid_message} = SDK.thread("inbox-1", "thread-1", options())
      end)

    refute logs =~ "PRIVATE_BODY_SENTINEL"
  end

  test "message with a different thread ID cannot be returned under a requested thread" do
    mock(fn _ ->
      Tesla.Mock.json(%{
        "id" => "thread-1",
        "messages" => [Map.put(gmail_message(), "threadId", "other-thread")]
      })
    end)

    assert {:error, :invalid_thread} = SDK.thread("inbox-1", "thread-1", options())
  end

  test "body-by-reference and unsupported leaf MIME never produce empty classification input" do
    for payload <- [
          %{
            "mimeType" => "text/plain",
            "body" => %{"attachmentId" => "body-reference", "size" => 100}
          },
          %{
            "mimeType" => "text/plain",
            "body" => %{"attachmentId" => "body-reference", "data" => "", "size" => 100}
          },
          %{"mimeType" => "text/html", "body" => %{"size" => 100}},
          part("text/calendar", "Calendar details"),
          part("text/enriched", "Important context"),
          %{
            "mimeType" => "multipart/alternative",
            "parts" => [
              part("text/plain", "Partial context"),
              part("text/calendar", "Missing context")
            ]
          }
        ] do
      mock(fn _ ->
        Tesla.Mock.json(%{"id" => "thread-1", "messages" => [gmail_message(payload)]})
      end)

      assert {:error, :invalid_message} = SDK.thread("inbox-1", "thread-1", options())
    end
  end

  test "archived read messages with omitted labelIds remain valid thread context" do
    mock(fn _ ->
      old = gmail_message() |> Map.put("id", "old-message") |> Map.delete("labelIds")
      Tesla.Mock.json(%{"id" => "thread-1", "messages" => [old, gmail_message()]})
    end)

    assert {:ok, [old, current]} = SDK.thread("inbox-1", "thread-1", options())
    assert old.labels == []
    assert current.labels == ["INBOX", "UNREAD", "IMPORTANT"]
  end

  test "attachment-only messages do not become empty classifier input" do
    attachment = %{
      "mimeType" => "application/pdf",
      "filename" => "a.pdf",
      "body" => %{"attachmentId" => "attachment-reference"}
    }

    for payload <- [
          attachment,
          %{"mimeType" => "multipart/mixed", "parts" => [attachment]},
          %{"mimeType" => "multipart/mixed", "parts" => [part("text/plain", ""), attachment]},
          %{
            "mimeType" => "multipart/mixed",
            "parts" => [part("text/plain", " \n\t"), attachment]
          },
          %{
            "mimeType" => "multipart/mixed",
            "parts" => [%{"mimeType" => "text/plain", "body" => %{"size" => 0}}, attachment]
          }
        ] do
      mock(fn _ ->
        Tesla.Mock.json(%{"id" => "thread-1", "messages" => [gmail_message(payload)]})
      end)

      assert {:error, :invalid_message} = SDK.thread("inbox-1", "thread-1", options())
    end
  end

  test "unnamed text attachments with inline data stay outside classifier content" do
    for mime <- ["text/plain", "text/html"] do
      disposition = [
        %{"name" => "cOnTeNt-DiSpOsItIoN", "value" => " AtTaChMeNt ; filename=ignored.txt"}
      ]

      attachment = part(mime, "PRIVATE_ATTACHMENT_SENTINEL", %{"headers" => disposition})

      visible =
        part("text/plain", "VISIBLE_MESSAGE", %{
          "headers" => [%{"name" => "Content-Disposition", "value" => "inline"}]
        })

      mock(fn _ ->
        Tesla.Mock.json(%{
          "id" => "thread-1",
          "messages" => [
            gmail_message(%{"mimeType" => "multipart/mixed", "parts" => [visible, attachment]})
          ]
        })
      end)

      assert {:ok, [message]} = SDK.thread("inbox-1", "thread-1", options())
      assert Content.read(message.body) =~ "VISIBLE_MESSAGE"
      refute Content.read(message.body) =~ "PRIVATE_ATTACHMENT_SENTINEL"

      for parts <- [[attachment], [part("text/plain", ""), attachment]] do
        mock(fn _ ->
          Tesla.Mock.json(%{
            "id" => "thread-1",
            "messages" => [gmail_message(%{"mimeType" => "multipart/mixed", "parts" => parts})]
          })
        end)

        assert {:error, :invalid_message} = SDK.thread("inbox-1", "thread-1", options())
      end

      root = gmail_message(attachment) |> update_in(["payload", "headers"], &(&1 ++ disposition))
      mock(fn _ -> Tesla.Mock.json(%{"id" => "thread-1", "messages" => [root]}) end)
      assert {:error, :invalid_message} = SDK.thread("inbox-1", "thread-1", options())
    end
  end

  test "AMP alternatives and related unnamed images do not block readable sales mail" do
    alternative = %{
      "mimeType" => "multipart/alternative",
      "parts" => [
        part("text/plain", "Development services pitch"),
        part("text/html", "<p>Development services pitch</p>"),
        part("text/x-amp-html", "AMP_SENTINEL")
      ]
    }

    related = %{
      "mimeType" => "multipart/related",
      "parts" => [
        alternative,
        part("image/png", "IMAGE_SENTINEL", %{
          "headers" => [%{"name" => "Content-ID", "value" => "logo"}]
        })
      ]
    }

    for payload <- [alternative, related] do
      mock(fn _ ->
        Tesla.Mock.json(%{"id" => "thread-1", "messages" => [gmail_message(payload)]})
      end)

      assert {:ok, [message]} = SDK.thread("inbox-1", "thread-1", options())
      assert Content.read(message.body) =~ "Development services pitch"
      refute Content.read(message.body) =~ "AMP_SENTINEL"
      refute Content.read(message.body) =~ "IMAGE_SENTINEL"
    end
  end

  test "AMP-only and image-only mail are preserved without meaningful readable text" do
    for payload <- [
          part("text/x-amp-html", "Unsupported body"),
          %{
            "mimeType" => "multipart/alternative",
            "parts" => [part("text/plain", ""), part("text/x-amp-html", "Unsupported body")]
          },
          %{"mimeType" => "multipart/related", "parts" => [part("image/png", "Image body")]}
        ] do
      mock(fn _ ->
        Tesla.Mock.json(%{"id" => "thread-1", "messages" => [gmail_message(payload)]})
      end)

      assert {:error, :invalid_message} = SDK.thread("inbox-1", "thread-1", options())
    end
  end

  test "exact addresses at company domains match exactly, not via domain keys" do
    mock(fn env ->
      if String.ends_with?(env.url, "/messages"),
        do: Tesla.Mock.json(%{"messages" => [%{"id" => "sent-1"}]}),
        else: Tesla.Mock.json(sent_metadata("Bob <bob@vendor.com>"))
    end)

    assert {:ok, keys} = SDK.contacted("inbox-1", ["bob@vendor.com"], options())
    assert keys == MapSet.new(["bob@vendor.com"])
    assert {:ok, keys} = SDK.contacted("inbox-1", ["alice@vendor.com"], options())
    assert MapSet.size(keys) == 0
  end

  test "small gzipped valid Google responses succeed through the bounded middleware" do
    body = Jason.encode!(%{"emailAddress" => "owner@acme.com", "historyId" => "100"})

    Tesla.Mock.mock(fn _ ->
      %Tesla.Env{status: 200, body: :zlib.gzip(body), headers: [{"content-encoding", "gzip"}]}
    end)

    assert {:ok, "100"} = SDK.history_id("inbox-1", options())
  end

  test "shared-provider correspondence is verified against exact To/Cc/Bcc recipients" do
    for header <- ["To", "Cc", "Bcc"] do
      mock(fn env ->
        cond do
          String.ends_with?(env.url, "/messages") ->
            assert env.query[:labelIds] == "SENT"
            assert env.query[:includeSpamTrash] == true

            assert env.query[:q] ==
                     ~s({to:"friend@gmail.com" cc:"friend@gmail.com" bcc:"friend@gmail.com"})

            refute env.query[:q] =~ "newer_than"
            Tesla.Mock.json(%{"messages" => [%{"id" => "sent-1"}]})

          true ->
            assert env.query[:format] == "metadata"
            assert Keyword.get_values(env.query, :metadataHeaders) == ["To", "Cc", "Bcc"]
            Tesla.Mock.json(sent_metadata("Friend <friend@gmail.com>", header))
        end
      end)

      assert {:ok, keys} = SDK.contacted("inbox-1", ["friend@gmail.com"], options())
      assert keys == MapSet.new(["friend@gmail.com"])
    end
  end

  test "search false positives do not protect an entire provider or local-part lookalike" do
    mock(fn env ->
      if String.ends_with?(env.url, "/messages"),
        do: Tesla.Mock.json(%{"messages" => [%{"id" => "sent-1"}]}),
        else: Tesla.Mock.json(sent_metadata(~s("friend@gmail.com" <friend@gmail.com.evil.com>)))
    end)

    assert {:ok, keys} = SDK.contacted("inbox-1", ["friend@gmail.com"], options())
    assert MapSet.size(keys) == 0
  end

  test "parent-company keys match true Sent recipients, not names embedded in another address" do
    mock(fn env ->
      if String.ends_with?(env.url, "/messages"),
        do: Tesla.Mock.json(%{"messages" => [%{"id" => "sent-1"}]}),
        else: Tesla.Mock.json(sent_metadata("known@mail.vendor.co.uk"))
    end)

    assert {:ok, keys} = SDK.contacted("inbox-1", ["vendor.co.uk"], options())
    assert keys == MapSet.new(["vendor.co.uk"])
  end

  test "Sent-search pagination continues past false positives to actual correspondence" do
    mock(fn env ->
      cond do
        String.ends_with?(env.url, "/messages") and env.query[:pageToken] == nil ->
          Tesla.Mock.json(%{
            "messages" => [%{"id" => "false-positive"}],
            "nextPageToken" => "page-2"
          })

        String.ends_with?(env.url, "/messages") ->
          assert env.query[:pageToken] == "page-2"
          Tesla.Mock.json(%{"messages" => [%{"id" => "actual"}]})

        String.ends_with?(env.url, "/false-positive") ->
          Tesla.Mock.json(sent_metadata("unrelated@gmail.com"))

        true ->
          Tesla.Mock.json(sent_metadata("friend@gmail.com"))
      end
    end)

    assert {:ok, keys} = SDK.contacted("inbox-1", ["friend@gmail.com"], options())
    assert keys == MapSet.new(["friend@gmail.com"])
  end

  test "malformed query keys cannot inject Gmail search operators" do
    Tesla.Mock.mock(fn _ -> flunk("invalid key must not contact Google") end)

    for key <- [
          ~s(friend@gmail.com" OR in:anywhere),
          "vendor.com} {from:me",
          "co.uk",
          "gmail.com"
        ] do
      assert {:error, :invalid_contact_keys} = SDK.contacted("inbox-1", [key], options())
    end
  end

  test "incomplete Sent search is an error, never proof there was no correspondence" do
    mock(fn _ -> Tesla.Mock.json(%{"messages" => [], "nextPageToken" => "more"}) end)

    assert {:error, :correspondence_limit} =
             SDK.contacted("inbox-1", ["friend@gmail.com"], options(max_pages: 1))
  end

  test "complete history is paginated, ordered, body-free and includes arrival IDs" do
    mock(fn env ->
      assert String.ends_with?(env.url, "/history")
      assert env.query[:startHistoryId] == "100"

      if env.query[:pageToken] == nil do
        Tesla.Mock.json(%{
          "historyId" => "103",
          "nextPageToken" => "next",
          "history" => [
            %{
              "id" => "101",
              "labelsRemoved" => [%{"message" => %{"id" => "message-1"}, "labelIds" => ["INBOX"]}],
              "messagesAdded" => [%{"message" => %{"id" => "new-message"}}]
            }
          ]
        })
      else
        assert env.query[:pageToken] == "next"

        Tesla.Mock.json(%{
          "historyId" => "103",
          "history" => [
            %{
              "id" => "102",
              "labelsAdded" => [%{"message" => %{"id" => "message-1"}, "labelIds" => ["INBOX"]}]
            },
            %{
              "id" => "103",
              "labelsRemoved" => [
                %{"message" => %{"id" => "message-1"}, "labelIds" => ["UNREAD"]}
              ],
              "messagesDeleted" => [%{"message" => %{"id" => "gone-message"}}]
            }
          ]
        })
      end
    end)

    assert {:ok,
            %{
              complete?: true,
              history_id: "103",
              added_message_ids: ["new-message"],
              deleted_message_ids: ["gone-message"]
            } = history} =
             SDK.history("inbox-1", "100", options())

    assert Enum.map(history.events, & &1.history_id) == ["101", "102"]

    assert {:ok, %{restored_ids: ["message-1"], retry_ids: []}} =
             Reconciliation.resolve(
               %Action{history_id: "100", message_ids: ["message-1"]},
               history
             )
  end

  test "history evidence records a timestamp before the first history HTTP request" do
    before_call = DateTime.utc_now()

    mock(fn env ->
      page = env.query[:pageToken]
      send(self(), {:history_requested_at, page, DateTime.utc_now()})

      if page == nil do
        Tesla.Mock.json(%{"historyId" => "100", "history" => [], "nextPageToken" => "second"})
      else
        assert page == "second"
        Tesla.Mock.json(%{"historyId" => "100", "history" => []})
      end
    end)

    assert {:ok, %{complete?: true, started_at: started_at}} =
             SDK.history("inbox-1", "100", options())

    assert_received {:history_requested_at, nil, first_requested_at}
    assert_received {:history_requested_at, "second", second_requested_at}
    assert DateTime.compare(before_call, started_at) in [:lt, :eq]
    assert DateTime.compare(started_at, first_requested_at) in [:lt, :eq]
    assert DateTime.compare(first_requested_at, second_requested_at) in [:lt, :eq]
  end

  test "expired history and incomplete pagination never become retry evidence" do
    mock(fn _ -> Tesla.Mock.json(%{"error" => "PRIVATE_BODY_SENTINEL"}, status: 404) end)

    assert {:ok,
            %{
              complete?: false,
              reason: :history_expired,
              events: [],
              started_at: %DateTime{}
            }} =
             SDK.history("inbox-1", "100", options())

    mock(fn _ ->
      Tesla.Mock.json(%{"historyId" => "102", "nextPageToken" => "more", "history" => []})
    end)

    assert {:ok, %{complete?: false, reason: :page_limit, events: [], started_at: %DateTime{}}} =
             SDK.history("inbox-1", "100", options(max_pages: 1))
  end

  test "history pagination loops and malformed records fail conservatively" do
    mock(fn _ ->
      Tesla.Mock.json(%{"historyId" => "102", "nextPageToken" => "same", "history" => []})
    end)

    assert {:ok, %{complete?: false, reason: :page_loop, started_at: %DateTime{}}} =
             SDK.history("inbox-1", "100", options())

    mock(fn _ -> Tesla.Mock.json(%{"historyId" => "102", "history" => [%{"id" => "broken"}]}) end)

    assert {:ok, %{complete?: false, reason: :invalid_history, started_at: %DateTime{}}} =
             SDK.history("inbox-1", "100", options())
  end

  test "a failed later history page discards partial evidence" do
    mock(fn env ->
      send(self(), {:history_requested_at, env.query[:pageToken], DateTime.utc_now()})

      if env.query[:pageToken] == nil do
        Tesla.Mock.json(%{
          "historyId" => "102",
          "nextPageToken" => "next",
          "history" => [
            %{
              "id" => "101",
              "labelsRemoved" => [%{"message" => %{"id" => "message-1"}, "labelIds" => ["INBOX"]}]
            }
          ]
        })
      else
        Tesla.Mock.json(%{"error" => "PRIVATE_BODY_SENTINEL"}, status: 500)
      end
    end)

    assert {:ok,
            %{
              complete?: false,
              reason: :gmail_unavailable,
              events: [],
              started_at: started_at
            }} =
             SDK.history("inbox-1", "100", options())

    assert_received {:history_requested_at, nil, first_requested_at}
    assert_received {:history_requested_at, "next", second_requested_at}
    assert DateTime.compare(started_at, first_requested_at) in [:lt, :eq]
    assert DateTime.compare(first_requested_at, second_requested_at) in [:lt, :eq]
  end

  test "missing nested history messages always produce timestamped incomplete evidence" do
    for field <- ~w(labelsAdded labelsRemoved messagesAdded messagesDeleted) do
      mock(fn _ ->
        Tesla.Mock.json(%{
          "historyId" => "102",
          "history" => [%{"id" => "101", field => [%{"labelIds" => ["INBOX"]}]}]
        })
      end)

      assert {:ok,
              %{
                complete?: false,
                reason: :invalid_history,
                events: [],
                added_message_ids: [],
                deleted_message_ids: [],
                started_at: %DateTime{}
              }} =
               SDK.history("inbox-1", "100", options())
    end
  end

  test "malformed SDK history decoding also returns incomplete evidence" do
    for response <- [
          "PRIVATE_BODY_SENTINEL-not-json",
          Jason.encode!(%{"historyId" => "102", "history" => [nil]})
        ] do
      mock(fn _ -> %Tesla.Env{status: 200, body: response} end)

      assert {:ok, %{complete?: false, events: [], history_id: nil, started_at: %DateTime{}}} =
               SDK.history("inbox-1", "100", options())
    end
  end

  test "malformed JSON from Google returns a fixed error without raw data" do
    mock(fn _ -> %Tesla.Env{status: 200, body: "PRIVATE_BODY_SENTINEL-not-json"} end)

    log =
      capture_log(fn ->
        assert {:error, :gmail_unavailable} = SDK.thread("inbox-1", "thread-1", options())
      end)

    refute log =~ "PRIVATE_BODY_SENTINEL"
  end

  test "oversized full thread bodies are stable unreadable content, including compressed replies" do
    body = String.duplicate("PRIVATE_BODY_SENTINEL", 450_000)

    for response <- [
          %Tesla.Env{status: 200, body: body},
          %Tesla.Env{status: 200, body: :zlib.gzip(body), headers: [{"content-encoding", "gzip"}]}
        ] do
      mock(fn _ -> response end)

      logs =
        capture_log(fn ->
          assert {:error, :invalid_thread} = SDK.thread("inbox-1", "thread-1", options())
        end)

      refute logs =~ "PRIVATE_BODY_SENTINEL"
    end
  end

  test "compressed and uncompressed oversized responses stop before SDK JSON decoding" do
    body =
      Jason.encode!(%{
        "emailAddress" => "owner@acme.com",
        "historyId" => "100",
        "padding" => String.duplicate("PRIVATE_BODY_SENTINEL", 450_000)
      })

    assert {:ok, %GoogleApi.Gmail.V1.Model.Profile{emailAddress: "owner@acme.com"}} =
             Poison.decode(body, as: %GoogleApi.Gmail.V1.Model.Profile{})

    for response <- [
          %Tesla.Env{status: 200, body: body},
          %Tesla.Env{status: 200, body: :zlib.gzip(body), headers: [{"content-encoding", "gzip"}]}
        ] do
      Tesla.Mock.mock(fn _ -> response end)

      log =
        capture_log(fn ->
          assert {:error, :gmail_unavailable} = SDK.history_id("inbox-1", options())
        end)

      refute log =~ "PRIVATE_BODY_SENTINEL"
    end
  end

  test "HTTP failures return only fixed categories and never echo a body or token" do
    for {status, category} <- [
          {401, :authorization_required},
          {403, :forbidden},
          {429, :rate_limited},
          {500, :gmail_unavailable}
        ] do
      Tesla.Mock.mock(fn _ ->
        Tesla.Mock.json(%{"error" => "PRIVATE_BODY_SENTINEL TOKEN_SENTINEL"}, status: status)
      end)

      log =
        capture_log(fn ->
          assert {:error, ^category} = SDK.thread("inbox-1", "thread-1", options())
        end)

      refute log =~ "PRIVATE_BODY_SENTINEL"
      refute log =~ "TOKEN_SENTINEL"
    end
  end

  test "token resolver failures never leak exception details" do
    {:ok, config} =
      Config.new(inbox(), fn -> raise "PRIVATE_BODY_SENTINEL" end, adapter: Tesla.Mock)

    refute inspect(config) =~ "PRIVATE_BODY_SENTINEL"
    assert {:error, :gmail_unavailable} = SDK.history_id("inbox-1", config: config)
  end

  test "Google's 403 quota responses are backoff errors rather than authorization failures" do
    for reason <- ["rateLimitExceeded", "userRateLimitExceeded", "dailyLimitExceeded"] do
      Tesla.Mock.mock(fn _ ->
        Tesla.Mock.json(
          %{
            "error" => %{
              "message" => "PRIVATE_BODY_SENTINEL",
              "errors" => [%{"reason" => reason}]
            }
          },
          status: 403
        )
      end)

      assert {:error, :rate_limited} = SDK.history_id("inbox-1", options())
    end
  end

  test "invalid parser inputs do not raise or retain raw response content" do
    assert {:error, :invalid_message} = Parser.message(%{body: "PRIVATE_BODY_SENTINEL"})
  end

  test "404 types identify the requested resource and never misidentify a missing profile" do
    mock(fn _ -> Tesla.Mock.json(%{"error" => "PRIVATE_RESPONSE"}, status: 404) end)
    assert {:error, :thread_not_found} = SDK.thread("inbox-1", "thread-1", options())
    assert {:error, :message_not_found} = SDK.thread_id("inbox-1", "message-1", options())

    Tesla.Mock.mock(fn env ->
      assert String.ends_with?(env.url, "/profile")
      Tesla.Mock.json(%{"error" => "PRIVATE_RESPONSE"}, status: 404)
    end)

    assert {:error, :not_found} = SDK.thread("inbox-1", "thread-1", options())
    assert {:error, :not_found} = SDK.thread_id("inbox-1", "message-1", options())
  end
end
