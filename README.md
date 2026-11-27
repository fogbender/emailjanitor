# Email Janitor

Email Janitor marks unwanted outreach Done while you keep your existing email
client. This is the MIT-licensed single-user engine and self-hosted service;
one user can connect multiple Google inboxes. The hosted application's tenancy
and billing live separately in `fogbender/emailjanitor-saas`.

**Under development.** No production service or deployable release yet. The
existing personal Janitor remains independent until a verified cutover.

The [implementation plan](docs/implementation-plan.md) records the agreed product
behavior and verification gates. Supported self-hosting will use AWS and SES,
with Gmail APIs/Pub/Sub for mailbox access. Hosted Janitor runs on Azure.

## Development

Install Nix with flakes enabled. From the source directory (a clone or extracted
source archive), run:

```sh
nix develop
mix deps.get
bash scripts/check
```

All normal tests use synthetic messages and isolated dependencies. Do not point
tests at a real inbox or shared database. Never commit credentials or email bodies.

`scripts/check` checks formatting, compiles with warnings as errors, then starts
a new temporary PostgreSQL cluster for the tests. It uses only a private Unix
socket and removes its database on exit. To run selected tests:

```sh
nix develop --command bash scripts/test test/email_janitor/executor_test.exs
```

## Implemented foundation

Versioned distilled preferences are available through `Preferences.install/1`
(migration 3), `snapshot/2`, `text/1` and `replace/5`. The host selects either all
inboxes or the snapshot's inbox after authenticating the conversation. Only the
distilled instruction belongs in this store; raw email, chat input and model
responses do not. Global and local instructions are each capped at 15,000 bytes,
keeping the composed preference text within the model adapter's budget.

Updates compare the snapshot's namespace, revisions and mailbox instruction
version, then bump affected inbox versions atomically. UUID effect receipts
deduplicate retries for seven days without retaining conversation text or text
hashes. Reusing a request UUID returns its original effect, even after a later
correction; callers compare that receipt's revision with current state before
describing what is active. Clearing a scope removes its older receipts. Writes
prune expired receipts; hosts also call `Preferences.purge_receipts/2` during
maintenance. The [migration registry](docs/migrations.md) reserves optional module
versions alongside the core sequence. Registration serializes
with global updates so a newly connected inbox cannot miss an invalidation. A
prepared cleanup also checks the current instruction version at its dispatch
fence; a correction that commits first cancels that old attempt through the
existing executor/policy path. A request already dispatched may still finish.
The conversational planner and authenticated email/web teaching workflow are
still being built; the preference API is its persistence boundary.

Host policy callbacks reserve and settle under database locks. Settlement rereads
the current durable outcome while excluding reconciliation and transition races;
retrying settlement cannot overwrite a newer outcome with stale uncertainty.
Blocked admissions retain one non-mutation candidate ID per inbox/exact message
set; admission promotes that same ID to an action. A later cancelled retry gets
a new reservation ID. Overlapping older blocked proposals are retired atomically
via `Policy.retire_candidate/4` when a newer proposal is blocked or admitted;
hosts remove only that old proposal's pending metadata, without recording a Gmail
outcome or refunding quota. Candidate markers contain IDs only, never email bodies.
Fresh proposals also retire superseded metadata from prepared cancelled actions.
Such work remains queued until fresh review supplies that evidence.

Hosts review authenticated threads through `Executor.review/8` with their
classifier, versioned instructions, Gmail adapter and the same `policy:` used for
execution. A fresh keep retires obsolete pending metadata; transport/model errors
leave it queued. Instruction-version and database snapshot checks prevent older
reviews from discarding newer work. `execute` also retires known ineligibility
observed during its deterministic prechecks. Public executor entry points reject
outer transactions so a failed host settlement cannot roll back a Gmail outcome.
Review has a 60-second budget covering Gmail reads, classification and metadata
retirement. A timeout returns `:executor_unavailable` and keeps pending work for
retry; configure provider request deadlines within that budget.

Hosts may pass `cleanup_target_ids:` to `Executor.review/8` from a verified
new-arrival eligibility proof. `Message.cleanup_target` separates that selection
from raw Gmail INBOX state. The model receives the remaining conversation as
context and returns one constrained decision per target in a single request;
missing, duplicate or context-only IDs invalidate the whole response. The model
budget remains at most five targets, 32KB preferences and 96KB complete context.
Unreadable/oversized content preserves pending work for retry, not retirement.
Existing correspondence, sent/draft and manual-restoration guards still protect
the full conversation before review and again before execution.

`Proposal.message_ids` are the Done subset; `evaluated_message_ids` also includes
kept targets; `inbox_message_ids` is the full reviewed raw INBOX snapshot. Execution
checks the exact full snapshot and full-thread fingerprint before mutating only
Done IDs. `Policy.reserve/6` receives the full snapshot in `Policy.Admission` so
the private SaaS can enforce its free whole-thread rule while paid and default
single-user deployments admit eligible subsets. Legacy five-argument policy
adapters reject partial admission without reserving quota. Partial retirement
withdraws evaluated or now-archived IDs only; unevaluated INBOX context keeps its
pending metadata and stable marker. Remaining IDs shrink durably on each partial
retirement, and the marker disappears when every member is accounted for.
Per-message review fences survive marker removal, so newer Keep decisions fence
older Done work, including a cached proposal whose execution starts later.
Scoped reviews carry their original database timestamp; a blocked cached proposal
must be reviewed afresh before another admission. Mixed Done categories retain
their per-ID enums in `message_categories`; the batch category is `mixed`.
These additions use [instance migration 6](docs/migrations.md); no body text is
part of this metadata.

- Conservative sender and correspondence guards, including configured relays,
  shared mailbox providers and public-suffix-aware parent-domain matching.
- Validated classifier boundary; transient content redaction and HTML extraction.
  Thin ReqLLM adapters target AWS Bedrock for self-hosting and Azure AI for the SaaS.
  Bedrock uses ExAws rotating EC2 role credentials, without developer profiles.
  No direct OpenAI/Anthropic adapters.
- Explicit repository/schema scopes, durable idempotent action intents, exact-ID
  Gmail mutation boundary and restoration protection, tested against PostgreSQL.
- Dedicated short-lived execution owners, single-host Linux identity, bounded
  dispatch and crash recovery. A dead
  owner that never dispatched permits a fresh checked attempt. Dispatched orphan
  actions and ordinary transport failures remain unresolved until fresh, complete Gmail history positively
  accounts for every message; empty history never licenses replay. Live owners
  remain protected, expired local owners are killed before recovery, and unknown
  hosts/runtimes cannot be taken over. Policy-aware hosts call
  `Executor.recover/4`, then `Executor.reconcile/5` with authenticated history
  started after recovery, and pass the same `policy:` to both. They execute new
  actions through `Executor.execute/5` with that policy. Defaults without a policy
  are the unlimited single-user deployment only.
  Do not wrap execution in a host transaction: it is rejected so the intent is
  committed before Gmail is called. Low-level store ownership APIs are internal
  executor primitives; hosts use the policy-aware Executor APIs above.
- Pure history-based ambiguous-action reconciliation and the shared bounded
  worker below, backed by the authenticated Gmail history adapter.

The executor uses a fake Gmail adapter in its unit tests. The Gmail SDK adapter
has separate HTTP-transport tests; model tests exercise both real SDK pipelines
against synthetic responses. No live Gmail account or model credentials are connected yet. There
is no running cleanup service, email transport, chat UI, billing, or cloud
deployment yet.

The SaaS will own identity/group routing and supply a trusted database schema
scope to this library. The library does not determine tenants or accept storage
scopes from model output or HTTP parameters. Query-prefix separation is covered
here; full SaaS authorization is a later integration gate.

## Model privacy boundary

Use only `[:email_janitor, :model, :stop]` for application model metrics; it emits
duration and a fixed status (`:ok`, `:error`, `:invalid`, or `:keep`, including preflight keeps
that never reach a model). The adapter removes the pinned SDK's
request lifecycle telemetry before dispatch, including the upstream exception
event that can otherwise contain raw text despite `payloads: :none`. Provider
preparation, signing and decoding still use the SDK. Tests attach an upstream
exporter and exercise failures for both providers. Raw payload tracing and dotenv
loading are disabled; calls fail closed if SDK debug mode is enabled. SDK retries
are disabled (`max_retries: 0`); the durable job owner controls
retry/backoff. Never put full SDK responses/errors into job arguments or reports.

Finch, the underlying HTTP client, publishes raw bodies and credential headers in
its own telemetry. Do not attach handlers/exporters to `[:finch, ...]` events or
enable runtime HTTP tracing. The model adapter checks for Finch handlers before
each call and fails closed if any are present; hosts must keep observer settings
fixed during calls. Only the metadata-only Janitor event above is supported.
Provider preparation also runs with logging disabled for that caller only,
restoring its prior logger setting afterward. A first request step disables
logging inside the SDK's separate short-lived dispatch/decoding task. This prevents the
pinned Bedrock Converse decoder's malformed-tool warning from persisting raw
model text; ordinary application logging in other processes stays available.
Oversized or structurally excessive raw HTML passed directly to the model adapter
is kept as `:unreadable_content` rather
than retried as a model outage. `Classifier.propose/4` requires the selected Inbox;
normal callers should use `Reviewer.review` to include safeguards and context.

Every actionable INBOX message is included in model context, with recent
already-done messages filling remaining context slots. More than five actionable
messages keeps the entire thread. Each header is capped at 4096 bytes and each
readable body at 16000 bytes, preserving UTF-8 boundaries. Ambiguous/unsupported
MIME, preferences above 32000 bytes, and complete encoded system/user context
above 96000 bytes keep the conversation rather
than submitting an incomplete or oversized review.

## Gmail SDK boundary

`EmailJanitor.Google.OAuth` supplies a shared, transient Google connection flow
using Assent 0.4's native JWT adapter. Build a trusted `OAuth.Config` from the
application's client ID, secret and registered redirect URI. `authorize_url/2`
accepts `:sign_in` (openid/email only) or `:connect` (also Gmail.modify and offline
consent). Every attempt uses random state, nonce and S256 PKCE. `callback/3`
accepts only a previously saved `OAuth.Session`; it verifies Google's RS256
signature, issuer, audience, authorized party, expiry, nonce and verified email.
Both documented Google issuer values (`https://accounts.google.com` and
`accounts.google.com`) are accepted; unrelated issuers remain rejected.
Connecting requires the granted Gmail scope and a refresh token. Token responses
are reduced to access/refresh credentials, Bearer type, expiry epoch seconds and
scope, inside redacted `Content`; ID tokens are discarded after verification.

The host must bind attempts to the initiating browser and account, expire them,
and atomically consume them once. Store `dump_session/1` encrypted server-side;
`load_session/1` validates fixed keys without dynamic atoms. Cookies should hold
only an opaque attempt reference. `refresh/2` preserves an omitted refresh token
and scope from the previous validated token. Endpoints and algorithms are fixed;
callback parameters cannot set SDK options. Provider requests disable redirects,
retries and logging. This module performs no durable storage and reads no machine
credential stores. The internal Config HTTP options accept only a trusted test
plug, never options from a browser request.
An expired/revoked refresh grant returns `:reauthorization_required`; outages,
rate limits and malformed responses return `:refresh_failed` for host backoff.

Google/OAuth HTTP operations also fail closed when any Finch telemetry handler is
registered: those events expose raw request headers and bodies independently of
SDK logging. Hosts must keep these handlers absent and must not change observer
configuration while calls run. `TransportPrivacy.check/0` exposes this preflight;
the library never removes a host's observers. Metadata-only application events
should be emitted separately from provider HTTP events.

`EmailJanitor.Gmail.SDK` uses Google's generated `google_api_gmail` client. Supply
an `EmailJanitor.Gmail.Config` with the connected `Inbox` and a zero-argument
token resolver returning `{:ok, access_token}` (or a redacted `Content` wrapper).
Token refresh and OAuth consent belong to the host; the adapter reads no global
credential stores. The resolver must identify that inbox, not whichever Google
account is currently active on the machine. Refresh early: a resolved token must
remain valid for at least the full 60-second execution budget, since preparation
freezes its verified token before admission.

Every operation verifies Google's profile email against that inbox before
accessing messages. Mutations accept 1–1000 distinct message IDs and remove only
INBOX. Sent-mail searches have no age cutoff, and search matches are checked
against actual To/Cc/Bcc metadata so partial-address matches do not establish a
relationship. Incomplete search or authorization failures stop execution.

`prepare_remove_inbox/3` resolves/refreshes credentials and verifies the profile
before an executor records dispatch. Its transient zero-argument closure performs
only the generated exact-ID batchModify request, with a default 10-second request
plus 5-second connect budget under the 30-second owner watchdog. Legacy
`remove_inbox/3` composes preparation and invocation. Hosts must never persist
closures, credentials, or captured environments; custom test transports must
honor the same bounded mutation contract.

Adapters that resolve credentials or verify the Google account must implement the
optional `Gmail.prepare_remove_inbox/3` callback. It runs before intent/admission
and returns an opaque zero-argument mutation closure with already-resolved,
frozen credentials valid for at least the entire 60-second execution window.
The closure performs only the exact-ID Gmail mutation, with transport timeouts
strictly below the 30-second watchdog; it must not refresh/resolve credentials,
check a profile, or perform other preparatory I/O. Only invoke that closure
inside the executor's durable dispatch fence; never persist it or its captured
credentials in a job. Preparation failure or termination creates no intent and
reserves no quota. Legacy lightweight adapters remain supported through
`remove_inbox/3`.

The executor also reserves a complete dispatch watchdog window inside its overall
execution deadline. If slow preparation exhausts that window, it fails before
admission; if database contention exhausts it after intent, the never-dispatched
intent is cancelled and its policy settlement is retried safely.


`history/3` fetches all pages and exposes ordered INBOX label changes plus arrival
and deletion IDs. Expired history, failed pages, pagination loops and limits
produce explicitly incomplete evidence, which must never authorize a retry.
Evidence includes `started_at`, captured before its first history HTTP request,
so recovery can reject a snapshot fetched before its ownership barrier.
`thread_id/3` resolves arrival IDs through minimal metadata. `watch/3` and
`renew_watch/3` register all mailbox changes with a provisioned Pub/Sub topic;
their registration cursor must not replace an existing processed-history cursor.
`stop_watch/2` stops this application's watch on deliberate disconnection.
The shared worker below handles watch renewal, guarded review/execution and
durable reconciliation when supplied by a trusted host. A separate supervised
notification poller records Pub/Sub hints.

Text parts are base64url-decoded transiently, HTML is converted to readable text,
and body content is wrapped in `Content`. Attachment bodies are not fetched.
Filename and Content-Disposition attachment markers both exclude a part, even
when Google provides unnamed plain/HTML attachment data inline.
Unsupported/malformed MIME and oversized text fail conservatively; this slice
supports UTF-8 text. The HTTP tests use synthetic responses and a per-connection
Tesla mock; no account tokens or actual mailbox bodies are test fixtures.
AMP alternatives and related inline images are omitted only when meaningful
supported text is available; AMP-only, image-only and attachment-only mail stays
untouched rather than becoming empty classifier input.

Google's generated connection currently omits the decompression bound required
by Tesla 1.23. A small connection middleware supplies an 8 MiB cap to that SDK
middleware and also limits uncompressed responses before JSON decoding. This
preserves the SDK protocol implementation without downgrading HTTP security fixes.

## Metadata-only notification ingestion

`EmailJanitor.Google.PubSub` uses Google's generated client for bounded,
authenticated pull and exact acknowledgement. Supply a trusted subscription and
an explicit short-lived service-token resolver. It reads no ambient credentials;
the service token is separate from each Gmail user's OAuth token. SDK transport
fixtures cover the actual generated requests. Pub/Sub IDs and acknowledgement
tokens are never treated as Gmail message IDs. Malformed deliveries remain
unacknowledged without blocking valid neighbors. Numeric history IDs normalize
to strings and unknown payload fields are ignored without retaining their values.

`Gmail.Ingestion.install(scope)` installs scoped migration 10. After the host calls
`Gmail.SDK.watch/3`, `Ingestion.baseline/3` saves that watch cursor without scanning
or cleaning existing mail. Restarting reads the existing checkpoint. Only an
explicit `reconnect/4`, fenced by the previous connection generation, establishes
a new baseline and discards old-generation discovery work. Watch renewal changes
only expiration; its registration cursor never advances the processing cursor.
OAuth refresh or reconsent after revoked credentials resumes the existing
generation and cursor. It must never be interpreted as deliberate disconnection
or used to call `reconnect/4` automatically.

Hosts can use `baseline/4`, `reconnect/5` and `activate/4` with
`on_baseline: fn checkpoint -> :ok end` and `expected_instruction_version:`.
The bounded database callback runs inside the mailbox-to-checkpoint transaction;
it binds the private connection epoch and active state to that exact generation.
A callback error rolls back both host activation and checkpoint/arrival changes.
`activate/4` resumes an existing generation without changing its cursor or baseline.
Perform watch/profile requests outside this transaction. Disconnect must lock the
mailbox and increment its version before changing private connection ownership;
the host callback rechecks the captured epoch and group/inbox ownership.

`NotificationWorker.poll_once/2` resolves each notification through the host's
trusted email-to-scope/Inbox router, commits a coalesced history hint, and only then
acknowledges it. Failed routes or commits remain unacknowledged.
A trusted host may return `{:ignore, :disconnected}` only for an exact stored,
deliberately disconnected inbox identity; it is acknowledged without a checkpoint
write or cleanup wake. Arbitrary unknown addresses remain unacknowledged. A revoked
credential for an existing bound epoch may still route normal metadata hints;
recording them never requires Gmail OAuth credentials or runs cleanup. A crash after
commit can safely redeliver the same hint. Hosts must supervise this bounded step
outside host transactions: ingestion writes reject outer transactions so an ack
cannot outrun its commit. Hosts must periodically call `Ingestion.catch_up/3`
even with no notifications: Gmail can delay or drop them. Catch-up atomically
queues discovered message IDs and advances only through closed, non-regressing
history records, with generation/cursor CAS. `Gmail.SDK.ingestion_batch/3` reads
one bounded API page; `more?: true` tells the host to schedule the next batch
immediately after its committed cursor. This avoids all-history page/count stalls.
The distinct `HistoryBatch` type has no `complete?` field and cannot authorize
ambiguous-action reconciliation; recovery still requires complete `history/3`.
Independent-connection tests cover commits, rollback and competing snapshots.

Pending work contains IDs, cursors and timestamps only. `eligible_thread/5` reads
thread content transiently and returns only the known current-generation INBOX
subset as a metadata eligibility proof. Older or unknown INBOX messages remain
context and never gain cleanup eligibility from sharing a conversation.
`authorize_proposal/4` requires nonempty distinct Done IDs within the nonempty
set of evaluated targets, including eligible messages classified Keep. Every
evaluated ID must remain in that proof and in durable same-generation discovery
records. Legacy proposals with no evaluated set use their Done IDs. Empty,
malformed, stale-generation and unknown-ID masks fail closed.

Hosts must carry that proof into the guarded review target mask and recheck it
before execution, retain connection-generation, instruction and manual-restore
guards, and use the Executor's fresh fingerprint and exact-ID checks. Free-plan
all-INBOX admission is a separate host-policy requirement; this proof itself does
not permit removing older context or bypassing the free quota. This slice supplies
the ingestion selection boundary and does not dispatch classification/mutations.

Expired history enters `:gap` and pauses discovery/eligibility. This deliberately
does **not** recover arrivals missed after Gmail's history retention expires.
Known gap-state inboxes still durably coalesce and acknowledge notification hints
without advancing their cursor, avoiding repeated subscription backlog. Fixed
authorization errors reach the host for reconsent without resetting the baseline.
An explicit reconnect leaves that missed backlog in the inbox; it is not outage
catch-up. A reviewed metadata-only recovery strategy or a surfaced reconnect
consequence is required before launch. Host scheduling, reconnect/forget lifecycle,
the private workload-auth token-file bridge and autonomous cleanup wiring remain
separate work. No service account keys or email bodies are introduced here.

## Self-host infrastructure foundation

The [AWS/OpenTofu and NixOS foundation](infra/README.md) includes isolated mail
transport, Gmail notification wiring, provider-mocked checks and a service module
that consumes a supplied release. It has not been applied and is not yet a complete
installer or deployable application. Run its local checks with:

```sh
nix develop --command bash scripts/check-infra
```


## Shared autonomous inbox worker

`Worker.install(scope)` idempotently installs the core, ingestion and scoped
migration 11 worker metadata. The host creates one `Worker.Config` per inbox,
binding its Scope/Inbox, Gmail and classifier adapters, current preferences,
current connection authorization, configured Pub/Sub topic and policy. Gmail
adapters used by the worker also implement watch/renew, thread lookup,
`thread_snapshot/3`, bounded ingestion and complete reconciliation history.
The Google-generated SDK supplies these operations; thread snapshots request
only `id,historyId` and never message content.

`Worker.step(config)` performs bounded work: settle/recover one durable action,
resume or atomically establish the host connection baseline, renew its watch,
commit one history batch, and review one conversation with at most five known
new-arrival targets. An ordinary restart or OAuth reconsent resumes the existing
generation. Only an explicit `lifecycle: {:reconnect, previous_generation}` can
establish a new baseline. The `on_baseline` callback and expected preference
version atomically bind that generation to the host's captured connection epoch;
no watch or model call runs inside the activation transaction.

`Worker.Server` supervises these steps with bounded concurrency (default two,
maximum eight), one active task per trusted inbox reference, bounded task
lifetimes and retry backoff. Supply `list: fn -> {:ok, refs} end` and
`resolve: fn ref -> {:ok, config} end` as bounded host database operations;
provider/model calls run in supervised tasks. Periodic catch-up remains necessary
even when Pub/Sub notifications are absent. Supervise the authenticated
`Gmail.NotificationWorker.Server` pull loop separately (trusted `source:`
adapter/config, database-only `router:`, optional `wake:` callback), and call
`Worker.Server.wake/1` after committing notifications when lower latency is needed.
That generic wake preserves failure backoff. Only a trusted explicit auth/config
repair or upgrade uses `wake/2` with a host-derived reference to reset that one
inbox's backoff; new references must still appear in the trusted list callback.

The host's `authorize` callback is checked again inside admission. It must use
bounded local database checks, and explicit disconnect/binding changes must lock
the core mailbox and increment its instruction version in the same transaction.
That version is checked again at the final dispatch fence. Worker admission uses
the Store's fresh clock under that lock, rather than a timestamp captured before
watch/model requests. Free-plan policy receives the complete raw INBOX snapshot,
including protected context, even though paid/unlimited cleanup may select only
eligible targets. Read/unread and other labels are never changed.

Configure `self_mail: fn headers -> Mail.Outbox.self_delivery?(scope, inbox.id,
configured_sender, headers) end` using the shared mail component when installed.
Only a successful delivery recorded for this exact scope, inbox, sender and
current Message-ID establishes Janitor mail. The callback removes such mail from
both model targets and model context; a matching sender alone establishes
nothing. Receipt lookup failure keeps mail pending and never feeds digest
upgrade wording to classification. This exemption does not authorize feedback.

Worker rows retain only IDs, revision hashes, versions, timestamps and fixed
outcomes, never bodies, credentials or raw model/provider responses. Stable
`:unreadable_content` keeps arrivals pending and probes only minimal thread
revision metadata every fifteen minutes until the revision or instructions
change; transient failures remain retryable with exponential backoff. Invalid
model output stops automatic candidate retries after eight consecutive invalid attempts while keeping
provenance for an explicit requeue. Unsupported policy contracts stay pending and
probe only revision metadata until content/instruction versions change; hosts must
bump the mailbox version when correcting a policy/configuration incompatibility.
Request-specific400/413/422 model rejections defer only that conversation;
authentication,429,5xx, quota/policy and transport outages preserve inbox-wide backoff.
Four distinct rejected/invalid conversations without a successful classification
trip inbox backoff too, bounding misconfiguration-induced400 bursts. Four repeated
rejections for unchanged content switch to metadata-only probes; candidate caps
remain paused until an explicit exact recheck.
Reports retain the underlying fixed failure reason even for local deferrals.
Durable last-attempt ordering lets never-attempted arrivals run before due failed
retries. Bulk host backlog discovery preserves requested backoff and exhausted
invalid-output caps; only an explicit exact candidate recheck resets them.
Notification wake-ups preserve failure backoff. Due local work schedules another
bounded step promptly instead of waiting the ordinary polling interval.
Terminal policy settlement retries
across restarts. Ambiguous mutations require fresh complete ordered history and
are never blindly sent again. Expired ingestion history explicitly pauses in
`:gap`; rebaselining cannot recover the unobserved outage backlog.

`Worker.queue_recheck(scope, inbox, candidate_uuid)` and `queue_backlog/2` queue
only previously identified metadata provenance, including actions cancelled
before dispatch. They accept no arbitrary Gmail IDs. Fresh review, current
connection generation, original identified IDs, restore/contact guards and policy
admission are all rechecked before mutation. The host supplies `allow_recheck`
for current paid/unlimited access; `{:blocked, :upgrade_required}` leaves
provenance intact without repeatedly classifying unpaid requests. Requeue known
backlog after an upgrade. Previously identified candidates can be rechecked after
an explicit reconnect without making unknown pre-baseline mail eligible.
## Google workload token helper

The isolated `google-auth-bridge` Nix package uses Google’s official Node SDK
for AWS IMDSv2 or an explicitly selected Azure managed identity. It signs and
exchanges workload credentials and impersonates the provisioned Google service
account for the Pub/Sub scope. The pinned SDK’s AWS client adds its target header
after signing; a small SDK subclass supplies the fixed configured audience to
the official signer before delegation and rejects unexpected signed headers.
Revalidate that upstream assumption on every SDK upgrade. It never receives Gmail credentials, email content,
or model input. There is no handwritten SigV4 or STS implementation.

A root-owned scheduled service runs:

```sh
emailjanitor-google-token --config /etc/emailjanitor/google-external-account.json --output /run/emailjanitor-google/token.json
```

Provision the SDK `external_account` JSON from the operator’s trusted infrastructure
outputs. Only the expected Google STS/IAM endpoints and exact AWS metadata source
or Azure metadata URL with an explicit `client_id` are accepted. Executables,
ambient AWS keys, custom credential endpoints, proxies, redirects and retries
are disabled. The helper caps requests at 10 seconds and its process at 45 seconds.
The Nix launcher starts Node with an empty environment, excluding startup proxy,
TLS, module injection and debug settings. Hosts must run this isolated launcher
without ambient instrumentation or observers.

The config must be owned by the helper user and not group/world writable. Use a
canonical path, including the direct store path for Nix-generated configuration;
the helper refuses configuration symlinks. Use a
canonical absolute output directory owned by root, with the application’s group
and mode `0750`. Tokens replace atomically with mode `0640`; failed refreshes keep
the previous file. Give the application read-only access to this directory and
no metadata-server/workload-credential access. Renew well before expiry, for
example every 15 minutes with a one-hour token; restart the helper after reboot.
The runtime file contains only `access_token` and epoch-second `expires_at`.
Supply `fn -> EmailJanitor.Google.ServiceToken.read(path) end` as the Pub/Sub
resolver. Missing, unsafe, malformed or expiring tokens fail closed without
ambient-account fallback or credential logging.

`nix build .#google-auth-bridge` builds and fixture-tests the pinned helper.
`nix develop --command bash scripts/check-google-auth` runs real SDK federation,
redirection/retry, configuration, redaction and atomic-file tests plus dependency
audit. Only synthetic workload identities and mocked HTTP are used. Service
unit wiring and deployment remain host integration work; no cloud resources
have been changed by this helper slice.
