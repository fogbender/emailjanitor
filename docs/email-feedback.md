# Incoming email feedback

This slice is not enabled or deployed. The shared parser/metadata workflow is
under integration and review; the final Conversation runner, threaded SES reply
transport and both host adapters still need their combined gate.

`Feedback.accept(config, incoming, raw)` is the `Spool.process` handler. It parses
bounded envelope/header hints only and commits a body-free receipt before returning
the workflow UUID. The normal Spool path then deletes S3 immediately. Gmail Sent
index lag is retried later using only that metadata, never retained SMTP text.

`Feedback.tick(config)` handles one due receipt. The trusted resolver rebuilds the
current sender-inbox binding; the generated Gmail SDK finds a unique current Sent
copy by exact canonical RFC Message-ID, refetches it and verifies actual Message-ID,
SENT/not-DRAFT, From, Janitor To/Cc/Bcc and Gmail internal date against trusted SES
time. Only this freshly fetched body reaches the maintained reply/forward parsers.
Raw SMTP References never select command context. `route_verified` receives only
the authenticated fresh Sent copy, and may choose an original recorded Janitor
context in the same scope. Assistant replies go to the authenticated sender inbox.

The pinned MIT Crisp reply/forward parsers run in a scrubbed one-shot process with
stdin/stdout framing, bounded bytes, time and memory, and no body arguments or logs.
Its `reply-parser` Nix package exports `emailjanitor-reply-parser`. A single plain
MIME alternative is preferred; unsupported HTML-only/attachment or ambiguous
interleaved/forward content receives a fixed clarification and makes no workflow
call. Quoted content is a separate untrusted evidence object, never authored input.

Migration13 stores IDs, sender address, verified bounded subject, timestamps,
retry state and fixed outcome enums. It stores no body, prose, token or transcript.
A stable verified command-inbox/RFC-ID request UUID deduplicates effects through
Conversation. Metadata-only reply recovery renders actual durable receipts or
honestly explains that an answer is unavailable. Outbox controls delivery and
never automatically resends ambiguous SES acceptance.

Unknown human senders can receive a fixed signup link only with passing transport
checks, aligned envelope sender, loop guards, one response per sender/UTC day and
an atomic global100/day backstop. Their transport-only recipient record is not a
Google account, identity or cleanup binding.

Native Elixir0.1.2 was evaluated (last Hex release2017). Maintained no-runtime-deps
Crisp libraries were selected for their current client/locale and linear-time
pattern support: https://github.com/crisp-oss/email-reply-parser and
https://github.com/crisp-oss/email-forward-parser . Parser rules are not custom
spam or sender heuristics and cannot grant mailbox permissions.
