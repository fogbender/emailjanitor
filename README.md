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

- Conservative sender and correspondence guards, including configured relays,
  shared mailbox providers and public-suffix-aware parent-domain matching.
- Validated, tool-free classifier boundary; transient content redaction and HTML
  extraction. A real model adapter is not connected yet.
- Explicit repository/schema scopes, durable idempotent action intents, exact-ID
  Gmail mutation boundary and restoration protection, tested against PostgreSQL.
- Dedicated short-lived execution owners, single-host Linux identity, bounded
  dispatch and crash recovery. A dead
  owner that never dispatched permits a fresh checked attempt. Dispatched orphan
  actions and ordinary transport failures remain unresolved until fresh, complete Gmail history positively
  accounts for every message; empty history never licenses replay. Live owners
  remain protected, expired local owners are killed before recovery, and unknown
  hosts/runtimes cannot be taken over. Hosts call `Executor.recover/3` and then
  `Store.reconcile/4` with authenticated history started after recovery.
  Do not wrap execution in a host transaction: it is rejected so the intent is
  committed before Gmail is called. Low-level store ownership APIs are internal
  executor primitives; a host should call `Executor.execute/4`.
- Pure history-based ambiguous-action reconciliation decisions. Its live Gmail
  history consumer and automatic recovery worker are not implemented yet.

The executor uses a fake Gmail adapter in its unit tests. The Gmail SDK adapter
has separate HTTP-transport tests; no live Gmail account is connected yet. There
is no running cleanup service, email transport, chat UI, billing, or cloud
deployment yet.

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
tokens are never treated as Gmail message IDs. Malformed delivery batches fail
closed without acknowledgement.

`Gmail.Ingestion.install(scope)` installs scoped migration 10. After the host calls
`Gmail.SDK.watch/3`, `Ingestion.baseline/3` saves that watch cursor without scanning
or cleaning existing mail. Restarting reads the existing checkpoint. Only an
explicit `reconnect/4`, fenced by the previous connection generation, establishes
a new baseline and discards old-generation discovery work. Watch renewal changes
only expiration; its registration cursor never advances the processing cursor.
OAuth refresh or reconsent after revoked credentials resumes the existing
generation and cursor. It must never be interpreted as deliberate disconnection
or used to call `reconnect/4` automatically.

`NotificationWorker.poll_once/2` resolves each notification through the host's
trusted email-to-scope/Inbox router, commits a coalesced history hint, and only then
acknowledges it. Failed routes or commits remain unacknowledged. A crash after
commit can safely redeliver the same hint. Hosts must supervise this bounded step
outside host transactions: ingestion writes reject outer transactions so an ack
cannot outrun its commit. Hosts must periodically call `Ingestion.catch_up/3`
even with no notifications: Gmail can
delay or drop them. Catch-up atomically queues discovered message IDs and advances
the cursor only for complete, non-regressing history, with generation/cursor CAS.
Independent-connection tests cover commits, rollback and competing snapshots.

Pending work contains IDs, cursors and timestamps only. `eligible_thread/5` reads
thread content transiently and preserves the whole conversation if any current
INBOX message lacks same-generation post-baseline eligibility. It returns only a
metadata eligibility proof. `authorize_proposal/4` rejects proposals outside that
proof and rejects proofs from a previous connection generation. Hosts must also
honor connection-generation fencing at final execution, retain the engine's
instruction/manual-restoration guards, and use the Executor's fresh fingerprint
and exact-ID checks. This slice does not dispatch classification or mutations,
and it does not implement a partial-message mask for mixed old/new conversations.

Expired history enters `:gap` and pauses discovery/eligibility. This deliberately
does **not** recover arrivals missed after Gmail's history retention expires.
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
