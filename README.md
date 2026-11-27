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
duration and a fixed success/error status. Do not export or log ReqLLM's raw
exception lifecycle events: upstream error objects can contain transient request
text even with `payloads: :none`. The SDK adapter discards those errors and returns
fixed categories. Raw payload tracing, SDK debug mode and automatic dotenv loading
are disabled. Normal tests cover echoed body text in HTTP errors and application
telemetry. SDK retries are disabled (`max_retries: 0`); the durable job owner controls
retry/backoff. Never put full SDK responses/errors into job arguments or reports.
