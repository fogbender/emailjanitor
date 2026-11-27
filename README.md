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
  hosts/runtimes cannot be taken over. Hosts call `Executor.recover/3` and then
  `Store.reconcile/4` with authenticated history started after recovery.
  Do not wrap execution in a host transaction: it is rejected so the intent is
  committed before Gmail is called. Low-level store ownership APIs are internal
  executor primitives; a host should call `Executor.execute/4`.
- Pure history-based ambiguous-action reconciliation decisions. Its live Gmail
  history consumer and automatic recovery worker are not implemented yet.

The Gmail adapter in the tests is a fake. Model HTTP tests exercise the real SDK
against synthetic responses, not live models or credentials. There is no OAuth connection, running
cleanup service, email transport, chat UI, billing, or cloud deployment yet.

The SaaS will own identity/group routing and supply a trusted database schema
scope to this library. The library does not determine tenants or accept storage
scopes from model output or HTTP parameters. Query-prefix separation is covered
here; full SaaS authorization is a later integration gate.

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

## Self-host infrastructure foundation

The [AWS/OpenTofu and NixOS foundation](infra/README.md) includes isolated mail
transport, Gmail notification wiring, provider-mocked checks and a service module
that consumes a supplied release. It has not been applied and is not yet a complete
installer or deployable application. Run its local checks with:

```sh
nix develop --command bash scripts/check-infra
```
