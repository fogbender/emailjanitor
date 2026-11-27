# Email Janitor

The [SES transport foundation](docs/mail-transport.md) documents the metadata-only
outbox, trusted inbound receipts, short-lived spool and remaining host contracts.
The [daily digest library](docs/daily-digests.md) adds local-21:00 scheduling,
frozen sender/subject snapshots and a supervised metadata-only worker.

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

Host policy callbacks reserve and settle under database locks. Settlement rereads
the current durable outcome while excluding reconciliation and transition races;
retrying settlement cannot overwrite a newer outcome with stale uncertainty.
Blocked admissions retain one non-mutation candidate ID per inbox/exact message
set; admission promotes that same ID to an action. A later cancelled retry gets
a new reservation ID. Overlapping older blocked proposals are retired atomically
via `Policy.retire_candidate/4` when a newer proposal is blocked or admitted;
hosts remove only that old proposal's pending metadata, without recording a Gmail
outcome or refunding quota. Candidate markers contain IDs only, never email bodies.

- Conservative sender and correspondence guards, including configured relays,
  shared mailbox providers and public-suffix-aware parent-domain matching.
- Validated classifier boundary; transient content redaction and HTML extraction.
  Thin ReqLLM adapters target AWS Bedrock for the one supported self-host setup
  and Azure AI for the SaaS. Bedrock uses ExAws's rotating EC2 role credentials,
  not developer profiles or model API keys. No direct OpenAI/Anthropic adapters.
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
- Pure history-based ambiguous-action reconciliation decisions. Its live Gmail
  history consumer and automatic recovery worker are not implemented yet.

The executor uses a fake Gmail adapter in its unit tests. The Gmail SDK adapter
has separate HTTP-transport tests; no live Gmail account is connected yet. There
is no running cleanup service, email transport, chat UI, billing, or cloud
deployment yet.
Model HTTP tests exercise the maintained SDK against synthetic responses, not live models or credentials.

The SaaS will own identity/group routing and supply a trusted database schema
scope to this library. The library does not determine tenants or accept storage
scopes from model output or HTTP parameters. Query-prefix separation is covered
here; full SaaS authorization is a later integration gate.

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
account is currently active on the machine.

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

`history/3` fetches all pages and exposes ordered INBOX label changes plus arrival
and deletion IDs. Expired history, failed pages, pagination loops and limits
produce explicitly incomplete evidence, which must never authorize a retry.
Evidence includes `started_at`, captured before its first history HTTP request,
so recovery can reject a snapshot fetched before its ownership barrier.
`thread_id/3` resolves arrival IDs through minimal metadata. `watch/3` and
`renew_watch/3` register all mailbox changes with a provisioned Pub/Sub topic;
their registration cursor must not replace an existing processed-history cursor.
`stop_watch/2` stops this application's watch on deliberate disconnection.
The automatic notification/watch-renewal/reconciliation worker remains future work.

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

## Self-host infrastructure foundation

The [AWS/OpenTofu and NixOS foundation](infra/README.md) includes isolated mail
transport, Gmail notification wiring, provider-mocked checks and a service module
that consumes a supplied release. It has not been applied and is not yet a complete
installer or deployable application. Run its local checks with:

```sh
nix develop --command bash scripts/check-infra
```

Adapters that resolve credentials or verify the Google account must implement the
optional `Gmail.prepare_remove_inbox/3` callback. It runs before intent/admission
and returns an opaque zero-argument mutation closure. Only invoke that closure
inside the executor's durable dispatch fence; never persist it or its captured
credentials in a job. Preparation failure or termination creates no intent and
reserves no quota. Legacy lightweight adapters remain supported through
`remove_inbox/3`.

The executor also reserves a complete dispatch watchdog window inside its overall
execution deadline. If slow preparation exhausts that window, it fails before
admission; if database contention exhausts it after intent, the never-dispatched
intent is cancelled and its policy settlement is retried safely.

## Model privacy boundary

Use only `[:email_janitor, :model, :stop]` for application model metrics; it emits
duration and a fixed status (`:ok`, `:error`, or `:keep`, including preflight keeps
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
Oversized or structurally excessive HTML is kept as `:unreadable_content` rather
than retried as a model outage. `Classifier.propose/4` requires the selected Inbox;
normal callers should use `Reviewer.review` to include safeguards and context.

Every actionable INBOX message is included in model context, with recent
already-done messages filling remaining context slots. More than five actionable
messages keeps the entire thread. Each header is capped at 4096 bytes and each
readable body at 16000 bytes, preserving UTF-8 boundaries. Ambiguous/unsupported
MIME and encoded email context above 96000 bytes keep the conversation rather
than submitting an incomplete or oversized review.
