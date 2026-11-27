# SES transport foundation

This slice supplies maintained ExAws SES/S3/SQS operations and a metadata-only
durable outbox/spool. It does not yet schedule digests, parse human conversations,
send signup instructions, run feedback workflows, or prove SES account readiness.
No live mail or cloud resources were used during its tests.

The host first installs `Store.install(scope)`, then `Preferences.install(scope)`
(scoped migration 3) if used, then `Mail.Store.install(scope)` (scoped migration 4;
see the [migration registry](migrations.md)). `Mail.Config.new/1` takes the trusted AWS region, exact sender,
spool bucket, SQS URL, SES receipt topic ARN and a zero-argument credentials resolver.
The resolver returns temporary `access_key_id`, `secret_access_key`, `security_token`
keywords. `Mail.Credentials.instance_role/1` uses the maintained ExAws EC2 role
chain with IMDSv2 and rotating cache; it reads no shared developer profile or
personal environment key. An Azure host supplies `fn -> Mail.Credentials.read(path) end`
for its isolated root helper's atomic runtime file. The file contains exactly
`access_key_id`, `secret_access_key`, `security_token` and epoch-second `expires_at`,
with 15-minute STS credentials. The reader bounds input, rejects non-regular or
symlinked files and group-writable/world-readable modes, and requires at least
60 seconds of validity. The SDK accepts the same 16 KiB session-token bound.
It rereads on every SDK preparation; it never falls back
to a developer profile or metadata endpoint. The host must own the parent
directory as root, allow the application group read/traverse only, and atomically
replace mode-0640 files.
The metadata precheck and file open are separate; this API does not make an
attacker-writable path safe or eliminate replacement races. Only the trusted
root helper may replace the file. Do not grant the web/app process
unrestricted instance-metadata access just for this adapter.

SDK operation construction, XML parsing and SigV4 signing belong to ExAws. The
HTTP adapter uses Req with redirects and both retry layers disabled, bounded
connection/response timeouts and a one MiB streaming response limit. Raw MIME
and outgoing content use redacted `Content`/`Message` structs. SDK credentials use
a redacted `Prepared` struct. No raw provider exceptions escape. The SDK caller's
logging is temporarily disabled during dispatch/parsing and restored afterward;
host logging in other processes remains available. Finch, ExAws and the private
mail SDK telemetry events must have no observers; preflight fails closed and
never detaches host handlers. Keep observer configuration fixed during calls.
Never attach a raw HTTP trace or log an unwrapped MIME message in host callbacks.

## Outgoing capability and replay

`Outbox.enqueue(scope, inbox_id, :digest | :assistant, reference_ids, dedupe_id)`
persists only UUID references, an inbox ID, kind, state and provider message ID.
The host owns the UUID's metadata meaning and supplies a stable dedupe UUID per
logical digest/response. `Outbox.deliver(scope, id, config, authorize, render)`
requires an authorizer returning the currently connected `Inbox`. Its address
must match the durable inbox row; no recipient from a model or renderer is used.
Authorization is checked again after rendering/credential preparation, under
the scoped mailbox lock in the same transaction as the send fence. Authorizers
must be DB-only: settlement/disconnect and dispatch use mailbox → public host
group/inbox → outgoing state order. Providers and rendering stay outside SQL.

The renderer receives the durable metadata row and returns `{:ok, Message}`.
It regenerates digest sender/subject lines or assistant text in memory, never
persists a completed email, and must not treat message content as authority.
The outbox commits `dispatching` before its single SES attempt. Success stores
`sent` and the SES message ID. Timeout, failure or crash after dispatch remains
`unresolved` or `dispatching`; those states are never resent automatically. A
pre-dispatch rendering/credential failure leaves `pending` and can be retried.
A proven deadline exhaustion before the SES closure runs also restores `pending`;
it is distinct from ambiguous acceptance after a request may have started.
This intentionally favors a missing email over a duplicate after ambiguous SES
acceptance. Calling from an outer database transaction is rejected.

An optional sixth `Outbox.deliver` argument is a trusted DB-only admission callback.
It executes after rendering/credential resolution, inside the short transaction
that locks the pending outbox row and commits its send fence. A rejected check
rolls back both host metadata and the fence; the provider remains outside SQL.
The digest layer uses this to reserve its current local dispatch day atomically.
Outgoing plain text is bounded to 3 MiB; maintained-SDK wire and conservative MIME
size tests keep it below SES v1's 10 MB message limit. Incoming MIME remains 1 MiB.

Confirmed sends also record the actual sender and connected recipient alongside
the returned bare SES MessageId. `Outbox.self_delivery?(scope, inbox_id, sender,
headers)` accepts the shared list of `{name, value}` headers and returns
`{:ok, boolean}` or `{:error, :self_mail_unavailable}` on storage failure. It
requires exactly one current From and Message-ID, the exact configured sender,
and same scoped inbox/sender/recipient `:sent` evidence. It never searches
References/In-Reply-To or treats the Janitor domain as a trusted relay.
The optional fifth argument is a trusted, database-only recipient predicate for
an inbox's recorded address history. It is consulted only after matching the
successful scoped send, provider ID and sender; an arbitrary normalized address
alone supplies no evidence. Hosts must keep the Google subject immutable for the
lifetime of an inbox ID. The single-user host uses
`SelfHost.Store.self_delivery?/3`, which supplies its subject-bound address history
so a rename preserves old digest and assistant evidence. The four-argument API
continues to require the current recipient address.
`Mail.MessageID.provider_id/1` projects a strict single RFC822 ID under
`amazonses.com` to its exact, case-sensitive provider local part; malformed,
duplicate, unknown or unsupported IDs receive no exemption. SES replaces the
[Message-ID header](https://docs.aws.amazon.com/ses/latest/dg/header-fields.html);
AWS's [header example](https://repost.aws/knowledge-center/ses-email-headers)
shows the returned provider ID as its local part. This is a conservative
non-destructive Keep exemption, not authentication for conversational feedback.
An unconfirmed/ambiguous send has no successful evidence and is never assumed
to be self-mail merely from its From address.

Remaining host integration: select the day's activity once, reserve its listing
and outbox intent atomically in a host-owned workflow, schedule 21:00 in the
browser timezone, retain only IDs/typed metadata, and regenerate transient text.
The digest is one per connected account, to that account, on activity days.
Define a conversation association using recorded outgoing SES IDs or a separate
opaque host capability; an arbitrary `In-Reply-To`, MIME From or subject does not
authenticate the sender. Reply threading and signed conversation capabilities
are deliberately not claimed implemented by this transport foundation.

## Trusted SES receipt and bounded spool

SES stores MIME in the SSE-KMS temporary bucket. The S3 action's optional SNS
notification (not a standalone SNS receipt action) sends SES envelope/verdicts
and the object reference to the restricted SQS queue, excluding MIME content.
Delivery headers can occur transiently in SNS/SQS; both the incoming and
encrypted failed-message queues retain messages for ninety minutes. Headers
and commonHeaders are dropped before database storage. The topic accepts
publishing only from the exact SES delivery role, whose trust names the exact
receipt rule. The queue accepts injection only from that topic. This IAM/TLS
pull path establishes provenance; `Receipt.parse/2` alone does not authenticate
JSON supplied through an arbitrary HTTP endpoint.

`SDK.poll/1` returns transient redacted notification bodies and receipt handles.
`Receipt.parse/2` requires the expected S3 action, topic, bucket, object key,
SES message ID, envelope recipients and explicit verdict statuses; direct-body
SNS/S3 ObjectCreated events are rejected. SES envelope and authentication verdicts
are transport evidence, not proof that a particular human sent a message.
The [SES notification contract](https://docs.aws.amazon.com/ses/latest/dg/receiving-email-notifications-contents.html)
describes the action's `objectKey` as `mail.messageId`. Accept that bare ID or
the exact `incoming/<messageId>` form for prefixed actions, then construct the
same canonical `incoming/<messageId>` reference. Neither form can select another
object or alter the configured bucket/prefix; live receipt round trips remain
a launch gate.
The host must match a known connected identity, authenticate its conversation,
reject bounces/automatic/bulk replies, and choose the trusted Scope/inbox. Where
this requires reading MIME first, keep the queue unacknowledged until the host
has committed its routing decision; do not choose a tenant from MIME From alone.
Once a receipt is classified as unprocessable, acknowledge it after committing
its purge decision (or confirming global orphan cleanup covers an unroutable
object), rather than repeatedly moving rejected notifications into the DLQ.

`Spool.accept(scope, inbox_id, receipt)` durably deduplicates the SES ID and stores
only the object key, envelope recipients/sender, fixed verdicts, deadline, claim
and outcome metadata. ACK the SQS handle only after that commit. `Spool.process`
passes the metadata row plus transient `Content` to the host callback. It accepts
`{:ok, workflow_uuid}`, `:ignored` or `:rejected`. Success/rejection commits a purge
intent before S3 deletion; a failed delete is retried without running the handler
again. A crash before that outcome can rerun the handler after its bounded lease.
The handler MUST independently deduplicate Gmail mutations, instruction edits and
outbox replies by the stable SES receipt ID. It must not directly perform an
unfenced external side effect and assume exactly-once callback delivery.
Inbound MIME has an explicit one MiB processing cap. A maintained S3 HeadObject
size check rejects a larger forward without downloading its body; the streaming
cap also catches growth after that check. This commits terminal `:too_large`
metadata and an immediate purge, returning `{:error, :mail_too_large}` to the
host instead of retrying it as an outage. The host can use the stable receipt ID
to issue one authenticated, connected-inbox response explaining the cap. Read
the typed result with `Spool.get/2`; never cache the oversized body as a workaround.
Repeated processing retains the typed `:mail_too_large` result while the metadata
row exists, so a host crash before its cap response can recover that decision.
Deduplicate that response independently by the stable receipt ID.

Every accepted receipt expires one hour after SES received it; failure/retries
never extend the deadline. Run `Spool.sweep(scope, config, marker \\ nil)` at least
minutely to purge expired rows including failed authentication/parsing. It
processes at most 100 rows per page in stable ID order, returning `{:ok, marker}`
or `{:error, :spool_cleanup_failed, marker}`. Continue each non-nil marker even
after failures so a failed early page cannot starve later objects. Start the
next complete pass with nil to retry failed objects.
`{:error, :outer_transaction}` and `{:error, :invalid_spool_marker}` are terminal
caller errors without a continuation; fix the caller before starting another pass.
Run `Spool.sweep_orphans/2` globally
for each spool bucket at least minutely, following each returned marker until nil.
On a per-object failure it returns `{:error, :spool_cleanup_failed, next_marker}`;
continue that marker too so a bad early object cannot block later pages, and
retry failed objects on the next complete sweep. This lists S3 references/LastModified only and deletes expired setup, malformed,
unroutable and orphan objects without reading MIME. Callbacks and MIME fetches
are bounded by a short-lived owner task. Cleanup can lag the hour by the sweep
interval and cannot delete while the host or AWS is unavailable. The one-day S3
lifecycle is a delayed emergency fallback, never a hard offline deletion promise.
No spool versioning, replication, archive or backup may be enabled; account-wide
backup policies must exclude its temporary-spool tag. Completed receipt rows
(including envelope/verdict metadata) are deleted ninety minutes after their
processing deadline. Durable workflow/effect deduplication belongs to the host's
metadata ledger; it must not depend on keeping spool rows forever. Partial
indexes keep the active cleanup scan independent of completed receipt history.
A deadline sweep deletes the object even while a bounded handler finishes. Its
same claim can still record the final outcome/workflow on the expired/deleted
metadata row without reviving the object or extending the deadline.

Feedback/prompt distillation remains a host integration: transient authenticated
reply → stable workflow UUID → immediate guarded action + persisted instruction
revision → a separate metadata outbox response explaining the result. A full
reply or generated response must never enter jobs, chat history, errors or DB.
Unknown-sender signup responses need a distinct explicitly authorized/rate-limited
host capability; the connected-inbox-only outbox does not grant that capability.

Tests use synthetic maintained-SDK HTTP responses and a fresh local PostgreSQL.
The live readiness gate remains consent/profile/refresh, new Gmail event, model
privacy/classification evaluation, SES sandbox/identity/DKIM, verified recipient,
actual inbound feedback round trip and immediate/failed-spool deletion.

Reply messages can carry bounded canonical parent references through the
maintained MIME and SES SDKs; see [email reply metadata](mail-threading.md).
