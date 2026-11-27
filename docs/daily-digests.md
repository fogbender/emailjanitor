# Daily digest library

This module schedules one minimalist activity digest per connected inbox at local
21:00. It supplies the metadata ledger, fixed snapshots, renderer and supervised
minute worker; the host supplies identity, live connections, hypothetical/quota
decisions, credentials and optional branding/upgrade footer. It has not sent real
mail or been deployed. Gmail cleanup throughput and plan limits are separate.

Install core, mail migration 4, then `Digest.install(scope)` (migration 5). After
connecting an inbox, call `Digest.configure(scope, inbox_id, browser_timezone, now)`.
The IANA timezone is validated with pinned tzdata 1.2.2; its auto-update is disabled
in this application so startup/tests need no timezone network service. Include
reviewed timezone-data updates in application releases as political rules change.
The library passes its database explicitly and does not change the embedding
application's global Calendar configuration. Reconfiguring a timezone preserves
the existing UTC cutoff and frozen snapshots.
Embedding applications must also set this before dependencies start (a library's
`config/config.exs` is not loaded by its parent application):

```elixir
config :tzdata, :autoupdate, :disabled
```

`Event.new(action_or_candidate_uuid, gmail_message_id, :done | :would_have_done,
sender_header, subject, occurred_at)` validates a stable typed source ID, exact
Gmail ID, parsed single sender address and bounded UTF-8 subject. It stores only
minimal sender/subject metadata, never a thread, body, reply or rendered email.
`Digest.record(scope, inbox_id, event)` is idempotent and transaction-compatible.
Record Done only after guarded cleanup is confirmed; use its actual action time,
not an old arrival date. Record cap decisions at their actual decision time too.
The host must record this in its durable confirmed-settlement transaction, or
retry from a body-free durable workflow, so a crash after cleanup cannot lose
the activity. A hypothetical is recorded once per Gmail message; a later actual
Done retires an unlisted hypothetical. `retire_hypotheticals/3` lets the trusted
host retire remaining extras after a restore or other final decision.

`Digest.tick(scope, inbox_id, now, claim_extras)` locks the schedule and chooses
the latest passed local 21:00 cutoff. It includes only unlisted activity at or
before that cutoff; a late tick cannot consume later-evening arrivals. Empty
days advance the checkpoint without creating mail. Timezone boundaries are
recomputed from IANA rules, handling 23/25-hour DST days rather than adding
24-hour offsets. A new connection starts at the latest cutoff, avoiding a
historical welcome/backlog cleanup.

The optional host callback is DB-only and executes inside the same Repo
transaction as snapshot/listing and `Mail.Outbox.enqueue`:

```elixir
fn inbox_id, digest_uuid, cutoff_utc, eligible_gmail_ids ->
  {:ok, exactly_claimed_gmail_ids}
end
```

Each invocation has at most 500 unique eligible IDs. Large digests call it in
disjoint chunks under the same single transaction and digest UUID. Only returned
IDs enter the hypothetical section, and every returned ID must belong to the
supplied eligible subset. Other metadata stays unlisted for a future eligibility
decision. The host must filter its active held/unlisted candidates by exact IDs
and cutoff; a permanent candidate's original insertion time alone cannot describe
later reactivation. Host errors or invalid subsets roll back the host listing,
snapshot, schedule checkpoint and outbox together. A self-host with no caps
records only Done and needs no hypothetical callback. No SaaS prices or paid
flags enter this engine.

The snapshot contains fixed metadata entry IDs; old snapshots never change as
backlog or preferences change. It is created atomically with its outbox intent.
`Digest.render(scope, digest_id, footer)` regenerates a transient plain-text
Message with sender and subject only, plus section labels and an explanation in
the first accepted digest that replying teaches Janitor. The optional host footer
is bounded to 2048 bytes; it can contain the SaaS upgrade link/copy without putting
billing into the library. The first-message explanation is based on previous
provider-confirmed sends; an ambiguous earlier send may cause the explanation
to appear again, which is safer than omitting it from the first received digest.

Digests have a conservative 32 KiB complete-text budget so ordinary multipart
plain/HTML replies quoting the digest fit the separate 1 MiB inbound processing
cap. A maintained-MIME regression exercises escaped HTML and quoted-printable
reply bodies. Signatures and attachments can still exceed the inbound limit;
those receive the explicit terminal size outcome rather than being retried.
Snapshots budget actual rendered header bytes, with reserved space for labels,
intro and footer. Metadata that cannot fit stays unlisted for a later digest;
unseen hypothetical IDs are never marked listed to satisfy an email size limit.
This transport bound is unrelated to daily free allowances or cleanup throughput.
Outgoing plain text is capped at 3 MiB, while incoming MIME remains 1 MiB. The
maintained SES SDK wire test measures worst-case UTF-8 form-urlencoding below
10,000,000 bytes and conservative MIME/base64 and quoted-printable bounds below
the [SES v1 message quota](https://docs.aws.amazon.com/ses/latest/dg/quotas.html).
The SDK still owns signing, protocol encoding and MIME generation; the library
does not implement an SMTP or MIME transport.

Always use `Digest.deliver(scope, id, config, authorize, clock: clock, footer: text)`
instead of sending its generic Outbox row directly. After rendering and credential
preparation, the DB-only admission hook locks the schedule and reserves the fresh
local dispatch day in the same transaction as `pending → dispatching`. This
prevents stale preparation-time dates from admitting a second digest after
midnight. The provider call remains outside SQL. A logical dispatch reservation,
stored as a UTC instant, is converted to the current timezone when comparing
delivery days after travel or a browser-timezone update. The date from the
previous timezone is not reused as a new-zone calendar key. A logical reservation,
not the later physical SMTP delivery time, defines the day; network delivery
cannot be made atomic with PostgreSQL. Generic outbox fencing and its no-auto-
resend policy still apply after ambiguous acceptance.

After downtime, recover one already-pending frozen digest and consume that local
day's digest slot. Keep newer unlisted activity for the next scheduled cutoff;
do not send one email per missed day or mutate a snapshot while a renderer could
already be reading it. Same-digest retries before dispatch can proceed, while
other digests are deferred for that local day. An ambiguous dispatched digest
is never resent. No activity is dropped or repeated to force calendar-day copy.

`Digest.Worker` runs immediately when its supervisor starts, then once a minute.
Host options are `:inboxes` (trusted `{Scope, inbox_id}` pairs), `:mail` (Mail.Config),
`:authorize` (scope/inbox → currently connected Inbox), optional `:claim_extras`
(scope plus the callback arguments above), `:footer` (scope/inbox → fixed text)
and `:clock` (zero-argument UTC clock). It drains pending never-dispatched mail
on retries even when that day's scheduling cutoff has already advanced. A failure
is isolated to its inbox and only fixed status counts leave the worker. Add it
to the embedding application's supervised release; NixOS then restarts that
release on failure/reboot. The database ledger, not an in-memory timer, owns all
cutoffs, listing decisions, daily slots and replay protection.

Lock ordering is shared with host settlement/disconnect: acquire the scoped
mailbox before schedule/activity and public host Group/inbox locks. Configure,
record, retire and claim follow it; dispatch obtains the same mailbox before
its outgoing/admission locks. No provider, model or complete email renderer runs
while these locks are held. The selection budget counts field bytes without
constructing a rendered body. Hosts must not acquire a new scoped mailbox while
already holding public Group locks for a different inbox; queue multi-inbox work
outside that transaction.

Tests use pinned real timezone data, controlled clocks, synthetic maintained-SDK
HTTP responses, separate PostgreSQL connections and a fresh local database. They
cover inactive days, DST, late-evening activity, cutoff subset/transaction rollback,
large metadata overflow, worker restart, concurrent claimers, a killed transaction,
ambiguous send recovery, fresh admission time and trusted host Scope separation.
