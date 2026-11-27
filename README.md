# Email Janitor

AWS self-host operators can start with the [setup CLI](docs/setup.md): private
key initialization, local configuration checks, official Google WIF config
generation, and the SOPS/OAuth/SES handoff. Setup leaves cleanup disabled.

The [SES transport foundation](docs/mail-transport.md) documents the metadata-only
outbox, trusted inbound receipts, short-lived spool and remaining host contracts.
The [daily digest library](docs/daily-digests.md) adds local-21:00 scheduling,
frozen sender/subject snapshots and a supervised metadata-only worker.

Email Janitor marks unwanted outreach Done while you keep your existing email
client. This is the MIT-licensed single-user engine and self-hosted service;
one user can connect multiple Google inboxes. The hosted application's tenancy
and billing live separately in `fogbender/emailjanitor-saas`.

**Under development.** No integrated production service yet. A
[locked Nix release](docs/release-packaging.md) builds the opt-in single-user host,
including its browser and background services. Installed startup is tested with
isolated synthetic providers; live provider verification remains a launch gate. The
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

The conversation foundation uses the same Azure/Bedrock SDK transport as
classification through `Models.SDK.object/4`. `Conversation.Planner.plan/6`
returns a transient typed proposal with inbox-bound reference tokens; email
content cannot supply a storage scope, credential or arbitrary tool. Incomplete
search results cannot authorize effects. Readable email passages are rejected from
distilled instructions. Small edits preserve unrelated instruction paragraphs
without generating a full 15,000-byte scope replacement. Grouped context is
read-only, so a grouped reference cannot discard independent neighboring rules.
Sender/subject text and decoded header names also participate in the copied-text
guard; canonical sender addresses remain usable in preferences.
Verbatim header phrases of 48 characters or more are conservatively rejected
inside a new instruction. Use a canonical sender address or a concise semantic
description for unusually long names/subjects. This copy guard supplements the
prompt and execution controls; it does not claim to detect every paraphrased or
split prompt injection.
These checks supplement the prompt; execution still
requires the immutable executor safeguards and the host's policy.

`Conversation.respond/3` uses a trusted `Conversation.Context` supplied by the
host. It resolves references inside the selected inbox, applies small preference
edits, and routes explicit Done requests through the same executor safeguards
and policy as automatic cleanup. Completion replies come from exact durable
message outcomes. Hosts must provide the policy and current connection guard;
model output cannot select a storage scope or a Gmail credential.
Read-only questions normally receive a transient model answer. If the preceding
request has uncertain effects, that turn reports its durable status instead of
letting generated prose claim success. An interrupted instruction update is
recovered from its saved preference-change receipt; without that proof the user
is asked to send the instruction again. Pinned message selections are never
replanned during recovery.

Email hosts can supply `Conversation.Evidence.new/3` as `request_evidence` to keep
the authenticated author's text separate from untrusted forwarded content.
`previous_request_id` pins a verified reply to its exact scoped predecessor;
an expired explicit predecessor never falls back to a newer unrelated request.

`Conversation.Ledger.install/1` installs migrations 8 and 9 for seven-day metadata-only
request/effect receipts and previous reference IDs. It stores no user request,
model response, search query, sender, subject or body. Hosts call `purge/2` during
maintenance. `Conversation.Outcome` derives completion claims from recorded
effects, preserves ambiguous results, and detects instructions changed since an
earlier request. A live request owner excludes duplicate effects; takeover requires
actual owner death, and completed receipts cannot be changed. The runner's Gmail
search/restoration capabilities and authenticated website/email entry points are
still being integrated; no live cleanup or production service is enabled here.

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
describing what is active. Clearing a scope removes its instruction text while
keeping recovery metadata for the same seven-day retry window. Writes
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
against synthetic responses. The opt-in host includes cleanup, email feedback,
digests and its browser UI; installed startup is tested locally. No live Gmail
account or model credentials are connected and no production deployment has run.
SaaS billing, tenancy and the fresh TNA LiveView foundation live in the private repo.

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
whose flake export defaults to the locked release package. It has not been applied and is not yet a complete
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
Watch-renewal failures have separate durable retry backoff and do not stop an
already active checkpoint from periodic history catch-up or local cleanup.
Verified Janitor deliveries are removed before safeguards, correspondence lookup
and classification; ordinary siblings retain all of those checks.

`Worker.Server.tasks/1` supplies Oban discovery and per-inbox cleanup tasks.
Supervise one `Jobs` instance in a host-owned schema (the single-user release uses
`ej_selfhost`, migration 104), with `cleanup: 2`, `discovery: 1` and
`notification: 1` queues. Pass its name as `jobs:`, plus bounded trusted
`list: fn -> {:ok, refs} end` and `resolve: fn ref -> {:ok, config} end` callbacks.
Only opaque references and fixed retry metadata enter Oban; credentials and
provider/model callbacks remain in memory. Durable retries survive process and
machine restarts, while domain effect ledgers still decide whether a mutation
may be attempted. Periodic catch-up remains necessary without Pub/Sub signals.

Merge `Gmail.NotificationWorker.Server.tasks/1` into the same runtime task map
(trusted `source:` adapter/config, database-only `router:`, optional `wake:`).
The optional timer-free `Worker.Server` facade takes the same cleanup options;
`wake/1` hints healthy work without bypassing failure backoff. Only a trusted
explicit auth/config repair or upgrade uses `wake/2` to reset one host-derived
reference. New references must appear in the trusted list, and removed epochs
are cancelled. Host references are opaque UTF-8 binaries of 1–256 bytes,
independent of Gmail IDs. Immediate authenticated chat remains transient.

A positively typed deleted-thread result retires the current pending recheck's
exact core, host and worker metadata, without a quota refund. The worker captures
a database timestamp before provider reads and revalidates connection generation,
instruction version, host authorization and the request version under database
locks. Newer review fences and unrelated selected-message siblings survive.
Profile 404s, unreadable content and temporary failures retain retry provenance;
unsupported partial host retirement pauses instead of withdrawing a wider grant.

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
Request-specific 400/413/422 model rejections defer only that conversation;
authentication, 429, 5xx, quota/policy and transport outages preserve inbox-wide backoff.
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
`Worker.queue_manual(scope, inbox, candidate_uuid, thread_id, exact_ids,
 authority_id: original_grant_uuid)` is a trusted host-only bridge for explicit
chat selections that predate the arrival baseline. The host must first verify
its durable authenticated manual-selection grant and current paid/unlimited
access. This API only binds existing scoped pending/cancelled-no-dispatch core
metadata; it never grants arbitrary archives or creates arrival records. The
host supplies `allow_manual_recheck(authority_uuid, all_source_ids)`, which
defaults to failure. It must verify every ID against active original grants,
current account identity and authorization, both before message fetch and at
admission. Original authority survives fresh actions and deliberate reconnect;
partial withdrawal must reject a source containing any withdrawn ID. Repeated
discovery must pass `refresh_authority: false`; it preserves retry deadlines and caps. A missing exact partial-retirement
capability pauses the affected candidate until explicit repair/recheck, without
repeated classifier calls or fallback to a whole-candidate withdrawal.

Candidate attempts carry a durable request version: selection changes and
explicit repairs increment it, while completion compares the version it began
with. A stale run cannot clear new selected IDs or overwrite repaired counters.
Unreadable candidate threads follow the same metadata-only deferral as arrivals.
Final admission preserves valid upgrade refusals and revoked-manual-proof
statuses; a quota/provider outage still uses inbox-wide backoff.

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

Targeted execution preserves uncovered Done work as a stable metadata-only
candidate when an earlier overlapping action is still live. It returns
`{:deferred, covering_action_id, recovery_result}` without another quota reservation
or Gmail intent. The covering result retains settlement/reconciliation retry IDs;
a fresh eligible subset can then pass normal admission. Candidate existence is
not new-arrival or paid-backlog authorization by itself.
Policy adapters must explicitly implement `retire_candidate_messages/4` to support
partial metadata withdrawal. Legacy `retire_candidate/4` is used only when all
remaining work is withdrawn; unsupported partial retirement rolls back before
changing either host metadata or the core candidate.

### Incoming email feedback (host integration)

`Mail.Feedback` adds a metadata-only M13 workflow, with no SMTP body, Gmail body,
reply prose, or auth tokens stored. A trusted host constructs `Feedback.Config`
with its transport-only Scope/Inbox, Mail config, absolute parser executable,
`route(envelope)` and `resolve(route_key)` callbacks. Initial routing identifies
only the sender's currently connected Google inbox. Neither SMTP headers nor SES
verdicts authorize a command. Known requests are durably accepted before the
spool purges the raw S3 object, including while Gmail Sent indexing is delayed.

The worker freshly verifies the Gmail account and searches an exact, unique
Sent RFC Message-ID. It requires the current sender, Janitor recipient, SENT
label, and an internal timestamp within one hour of the SES receipt. It parses
only that authenticated Sent body. Maintained Crisp reply/forward parsers run in
a bounded one-shot Nix executable (`.#reply-parser`, `emailjanitor-reply-parser`),
with separate authored instructions and untrusted forwarded evidence. Unsupported
MIME, ambiguous forwards, and interleaved quotes receive a clarification.

`Feedback.Binding.route_verified(fresh_sent)` constructs the command Context
only after authentication, using scoped confirmed Janitor outgoing references.
`Feedback.Reference.delivery/3` is strict about the current recipient; `/4`
accepts a trusted, exact subject-bound historical-recipient callback for renamed
Google accounts. The host may return `{:clarify, sender_context}` for an expired
or ambiguous reference, without executing a guessed conversation. A referenced
digest may address another inbox only within the same trusted Scope; the reply
still goes to the authenticated sender inbox. SMTP References are never passed
to the routing callback. Hosts must derive the original conversation ID and,
where present, exact prior request ID from their durable outgoing reference.

`Feedback.accept(config, incoming, raw_content)` is the `Spool.process` handler;
`Feedback.tick(config)` performs one due metadata receipt. Hosts bound worker
concurrency and call `Feedback.Ledger.purge(scope, now)` during maintenance. They
supply current DB-only guards and `respond(request_uuid, authored, evidence)` /
`render(request_uuid)` functions. Request UUIDs depend only on the scoped inbox
and canonical RFC ID. A reply interrupted after execution can be rebuilt from
durable effect metadata; an unretained read-only answer gets an honest fixed
fallback. Ambiguous SES dispatch is terminal, with no automatic resend. Unknown
human senders can receive a configured signup link, limited to once per sender, plus a global 100-new-senders/day abuse backstop, with no Gmail inbox provisioned for Janitor.

This is library plumbing tested with isolated PostgreSQL and synthetic HTTP.
It is not activated, and real Google/SES delivery and threaded replies still
need the final host/release integration gates.
## Exact-message restoration and search

`Gmail.SDK.search(inbox_id, query, options)` returns at most ten message/thread
references and an explicit `truncated` flag. It uses only generated SDK metadata
fields and never logs or persists the query. Callers must refine ambiguous or
truncated searches before selecting effects; message bodies require an explicit
subsequent scoped fetch.

`Restore.apply(scope, inbox, effect_uuid, action_uuid, exact_ids, gmail, options)`
restores only confirmed applied IDs from that exact scoped Janitor action.
Migration 7 is installed with the core. Requested IDs are protected durably
before the single generated-SDK add-INBOX operation; read/unread and all other
labels are preserved. The source action is not blanket-marked restored. Receipt
UUIDs bind the action and exact selection; duplicate or ambiguous effects never
auto-dispatch again. Proven dead owners with no dispatch marker may be cancelled,
allowing a fresh explicit request UUID. Overlapping unresolved effects stay blocked.

`Restore.outcome/3` reads an effect without network access: positive wire proof
is `{:done, id}`, a live owner is `{:prepared, id}`, proven dead pre-dispatch
owners are `{:cancelled, id}`, and dispatched or unknown-owner ambiguity remains
`{:unresolved, id}`. `Restore.overlap_outcome/4` distinguishes live overlapping
requests from permanent ambiguity; a completed wire awaiting only reporting does
not block a new explicit request. These reads do not dispatch or settle effects.

Hosts must pass `authorize: fn -> :ok | {:error, atom} end` and the current
`expected_instruction_version:`. Authorization is bounded DB-only work and runs
again under the final mailbox fence; disconnect must atomically increment that
mailbox version. An Inbox UUID must retain one immutable Google subject: address
changes for that subject are allowed, a different subject needs a new Inbox UUID.
The host guard enforces that invariant for the referenced action. Credentials
are frozen and verified before durable admission. Callers must not persist the
prepared closure. Forget/delete workflows remove manual_restore_protections
and restore_effects before actions/inboxes. No bodies, search text or tokens
enter either restoration table.

The source action records the full fresh observed thread IDs. Admission and
the final dispatch fence both check restoration protections under the mailbox
lock; a sibling cannot slip through a concurrent restore. Pre-migration prepared
intents without observed context must cancel and obtain a fresh review.

Only authoritative 401/403/429 responses from the generated SDK's single
batch-modify call produce an unapplied rejection proof. Those receipts cancel
and permit a fresh explicit request UUID after repair. Transport failures remain
ambiguous and never automatically repeat the Gmail mutation.
An observer-privacy refusal detected locally before HTTP is also a no-wire proof;
it cancels that effect instead of leaving a permanent ambiguous reservation.

A successful restore durably records `Effect.applied_at` and the exact original
action's `restored_message_ids` before reporting settlement. The bounded DB-only
`on_restored(action_id, exact_ids)` callback can withdraw pending digest activity;
hosts with digests must wire it. Callback failure preserves positive wire proof.
`Restore.pending_settlements/3`, `Restore.settle/4` and duplicate-UUID calls retry
only DB settlement, without Gmail. Requested protections are not positive wire
evidence; historical action IDs keep an old restore from withdrawing newer work.
Restoration settlement uses the trusted `policy:` option for exact retirement of
older pending/cancelled metadata, without charging or refunding quota. It uses
the positive effect timestamp and per-ID review fences, preserves unrelated IDs
and newer accepted requests, and never constructs an invented review snapshot.
Hosts that persist worker candidates must also retire the same exact IDs from
`Worker.Ledger` in their policy callback in that transaction, preserving unrelated
arrival provenance. Repeated exact retirement is idempotent.
Explicit rechecks and explicit changed manual selections atomically fence older reviews;
ordinary scheduler discovery does not refresh that authority.
Every accepted explicit `queue_manual` call fences its exact IDs and advances
the request version, including new rows and unchanged selections. Trusted host
discovery or replay must pass `refresh_authority: false`; structural selection
repair then preserves the original authority age. Explicit repair still uses
`queue_recheck` to reset paused or capped work.
The 30s mutation watchdog ends after the provider call; positive proof and
reporting use the remaining overall 60s owner budget, including database waits.


### Retained Google grants

The opt-in single-user host stores every received, canonical offline grant under
its immutable Google identity. A new consent commits its encrypted capability
before a separate binding/publication transaction, so failed validation, stale
publication or a SQL rollback cannot erase it. Repeated refresh IDs are deduplicated
with a domain-separated HMAC using the existing credential master. Only encrypted
authentication JSON and metadata are retained; no email bodies are added.

Superseded grants stay dormant while a newer connection is active. Revoking one
may invalidate other grants for the same Google user/project. Disconnect stops
local work immediately, then retires one saved snapshot per bounded worker tick.
A callback received while retirement is fenced is retained without activation.
Only the exact snapshot covered by a provider result is erased; a newer recapture
survives. Reconnection stays fenced until all retained capabilities are settled.

Refresh ownership is committed before SDK wire I/O. SDK replies are captured
independently before normalization, version checks or credential publication.
Retirement waits for active refreshes. A confirmed-dead owner receives a physical
30-second quarantine, covering the SDK's connect10s + receive15s bounds even after
a wall-clock jump. A lost response remains explicitly uncertain. Success from the
project-wide revocation endpoint can resolve that uncertainty; an invalid old
refresh token alone cannot prove an uncaptured rotation gone. In that case local
access stays stopped and the existing exact local operator confirmation of ALL
former Google access removed is required. Fresh captures invalidate stale manual
confirmation IDs. Provider calls never run under SQL locks.

These facade calls belong outside caller-owned SQL transactions. The maintained
browser host observes that boundary; a host must not wrap OAuth exchange/capture
in a transaction that it may later roll back. Migration105 preserves legacy
in-flight retirements and refuses rollback while grants or uncertain refreshes
remain. Keep the credential master stable, complete retirement before a supported
schema rollback, and never downgrade to a host that ignores the retained ledger.
