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

The Gmail adapter in the tests is a fake. There is no OAuth connection, running
cleanup service, email transport, chat UI, billing, or cloud deployment yet.

The SaaS will own identity/group routing and supply a trusted database schema
scope to this library. The library does not determine tenants or accept storage
scopes from model output or HTTP parameters. Query-prefix separation is covered
here; full SaaS authorization is a later integration gate.

## Self-host infrastructure foundation

The [AWS/OpenTofu and NixOS foundation](infra/README.md) includes isolated mail
transport, Gmail notification wiring, provider-mocked checks and a service module
that consumes a supplied release. It has not been applied and is not yet a complete
installer or deployable application. Run its local checks with:

```sh
nix develop --command bash scripts/check-infra
```
