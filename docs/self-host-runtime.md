# Single-user host control plane

`EmailJanitor.SelfHost` is the opt-in AWS host's fixed-owner facade. This slice
provides configuration, encrypted Google grants and connection lifecycle storage.
Browser setup, cleanup/conversation worker startup and inbound email integration
are separate integration gates; this storage slice alone is not a running host.
The shared library's ordinary application startup remains unchanged.

The concrete `SelfHost.Repo` uses a Unix-socket PostgreSQL connection. Its scope
is always `ej_selfhost`; browser parameters and model output cannot select a repo
or schema. Host migration 100 follows enabled shared migrations; browser-owned
attempt/session migration 101 follows it. No SaaS billing, tenant or Group exists.

`Config.load/1` reads trusted environment settings. Required settings are
`JANITOR_OWNER_EMAIL`, HTTPS `JANITOR_PUBLIC_URL`,
`JANITOR_CREDENTIAL_KEY_FILE` (exactly 32 raw bytes) and
`JANITOR_SECRET_KEY_BASE_FILE` (at least 64 bytes). Plain HTTP is accepted only
for a loopback origin. Runtime secret files must be regular files with no
group-write/world access and cannot be Nix-store paths. SOPS runtime symlinks
remain usable. File reads are bounded. The optional Google Web client JSON must
include the exact public URL plus `/auth/google/callback`. The AWS reference uses
Bedrock in `us-east-1`; neither a provider selector nor developer API keys enter
this host configuration. Missing Google setup is explicit in `status/1`.

Only the shared OAuth SDK's server-verified `OAuth.Result` may enter owner
authorization or connection. The first owner sign-in must match the configured
email, then its immutable Google subject is pinned. Later sign-ins require that
subject, including after an address rename. `owner?/1` is a database-only boolean
check suitable for revalidating each authenticated browser request.

`connect(owner_subject, result, browser_timezone)` stores minimal connection
identity and an AES-256-GCM encrypted, strictly validated Google token object.
Ciphertext is bound to its purpose and inbox ID. Stable master key material must
stay outside database backups; losing it requires reconnecting the accounts.
`seal/3` and `open/3` also support encrypted OAuth attempt data with a separate
purpose/opaque ID, returning only fixed errors. Tokens never enter ordinary
inspection, jobs, logs, a checked-in file or an unencrypted database column.

Each InboxID is derived from its verified Google subject and never reassigned.
Reusing an address with a different Google subject creates a different inbox,
retains the historical old ID and disconnects its old grant atomically. Host
migration 100 replaces the core unique-address index in this host scope only.
Same-subject address changes preserve the account's ID/cursor but increment its
connection epoch and core instruction version, fencing prepared old-address work.
The checkpoint address changes in the same transaction after verifying the
existing subject/address binding; its generation and cursor remain usable.
Connection lifecycle changes serialize without holding provider calls under SQL.

Explicit disconnect clears encrypted credentials and increments the epoch and
instruction guard. Ordinary refresh/reconsent preserves the epoch/cursor. Refresh
uses the shared maintained OAuth SDK outside SQL and publishes with an exact
credential-version check: a late response cannot revive a disconnected grant or
overwrite newer consent. Revoked grants clear credentials, require reauthorization
and invalidate prepared work. Each SDK resolver captures its explicit inbox and
epoch; there is no ambient Google account or machine credential fallback.
Concurrent refresh losers re-read a valid winning grant. A stale invalid-grant
response likewise uses newer consent instead of reporting a false reconnect need.

Only account IDs, connection state, timezone, encrypted grants and typed outcomes
persist here. Email bodies, raw replies, rendered digests and conversation
transcripts do not belong in these tables. Tests exercise real SDK refresh wire
fixtures, disconnect/reconsent races, owner/address reuse, ciphertext tampering,
callback-origin checks and runtime secret bounds against fresh local PostgreSQL.
