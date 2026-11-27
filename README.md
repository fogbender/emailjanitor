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
The automatic watch/notification/reconciliation worker remains future work.

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
