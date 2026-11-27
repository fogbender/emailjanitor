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

Explicit disconnect atomically removes ordinary resolver access, increments the
epoch/instruction guard and moves the existing encrypted credential into the
metadata-only retirement queue (host migration 103). A separately supervised
worker revokes the stored offline refresh token through the pinned official
Google SDK, outside database locks. It clears the pending ciphertext only after
HTTP 200, or exact provider rejection establishing that the saved token is
unusable. The latter reports only local access removal, not project-wide
permission revocation. Generic failures retain the encrypted capability and a
bounded retry. Repeated disconnect is idempotent.

Fresh consent for the same immutable Google subject remains blocked while any
old revocation can still run, even through another OAuth client or address. A
dead BEAM owner is insufficient subprocess-death proof. A persisted retry time
is only a scheduling hint: after confirming death, recovery waits 20 physical
seconds outside SQL, then revalidates the exact request/owner and death proof
under the mailbox lock. This bounds the final possible 13-second SDK helper even
if the wall clock jumps forward. Live or unknown owners stay blocked. The whole
operation remains bounded by its 60-second owner and 70-second job watchdogs.
Current successful calls wait for the helper's exit status. If Google's SDK already rejected the saved refresh grant
and the ordinary resolver erased it, local disconnect can complete without
claiming Google project permissions were removed, provided no old revocation is
pending. An unexplained missing capability is displayed as requiring manual
cleanup rather than falsely claiming success. Use a new isolated Google Cloud
project: revocation affects every OAuth client and scope in that project, so
reusing the old personal Janitor/Inbox Zero project is unsafe for live tests.

Ordinary refresh/reconsent preserves the epoch/cursor;
reauthorization after a revoked grant keeps the newly fenced epoch. A durable `reset_baseline`
marker distinguishes deliberate reconnect from reauthorization and records the
old checkpoint generation. Activation requires a different, nonnil checkpoint
generation in the same transaction; a mistaken resume of the old generation is
rejected. The marker clears only when the worker's baseline transaction commits.
Provider refresh uses the shared maintained OAuth SDK outside SQL and publishes with an exact
credential-version check: a late response cannot revive a disconnected grant or
overwrite newer consent. Revoked grants clear credentials, require reauthorization
and invalidate prepared work. Each SDK resolver captures its explicit inbox and
epoch; there is no ambient Google account or machine credential fallback.
`Store.refs/0` exposes internal lifecycle pairs; a scheduler must use the
`Store.worker_refs/0` adapter, whose bounded opaque binary keys include the
connection epoch. `fetch_binding/1` decodes those keys and checks the live epoch;
hosts normalize the verified binding back to an internal pair before building
credential or policy closures.
Concurrent refresh losers re-read a valid winning grant. A stale invalid-grant
response likewise uses newer consent instead of reporting a false reconnect need.

Only account IDs, connection state, timezone, encrypted grants and typed outcomes
persist here. Email bodies, raw replies, rendered digests and conversation
transcripts do not belong in these tables. Tests exercise real SDK refresh wire
fixtures, disconnect/reconsent races, owner/address reuse, ciphertext tampering,
callback-origin checks and runtime secret bounds against fresh local PostgreSQL.

The opt-in runtime builds SDK capabilities from each connection's own encrypted
grant and immutable Google subject. A durable manual command records only its
authenticated owner, inbox, conversation/request IDs, exact selected message IDs
and connection epoch (host migration 102). Refresh preserves the authority;
disconnect or an address rename invalidates it. The unlimited self-host policy
stages sender/subject metadata before a Done intent and confirms only durable
applied IDs. Exact retirement also narrows worker provenance so a corrected
message cannot strand an unrelated sibling.

Receipt intake acknowledges SQS only after durable metadata acceptance. A
separate database-backed processor resumes raw inputs after a crash, even if the
queue delivery was already acknowledged. Incoming SMTP content supplies routing
hints; instructions are read from a fresh authenticated copy in the connected
account's Sent folder. Digest/assistant context comes from confirmed, scoped SES
delivery evidence. Neither SMTP References nor model fields select an inbox.
Body parsing and authentication failures cannot extend the one-hour processing
TTL. Independent cleanup jobs attempt deletion at least minutely and drain every
continuation, including failed pages. Provider outages or an offline host can
delay physical deletion; S3 lifecycle is a delayed fallback. No raw spool is
versioned or backed up. Reply recovery renders metadata receipts, or gives an
honest fixed clarification when no conversational answer was retained.

The NixOS module passes three SOPS runtime files through `LoadCredential`:
`/run/secrets/emailjanitor/credential-key`, `web-secret`, and `google-client.json`.
The Google JSON must authorize the exact `JANITOR_PUBLIC_URL` origin plus
`/auth/google/callback`. Never put those file contents in Nix or OpenTofu state.
The module runs ascending migrations before startup, keeps PostgreSQL on its
local Unix socket, disables core dumps/distribution, and preserves access to
boot/process identity needed for durable owner recovery. The maintained reply
parser is supplied from the same pinned flake.
The module also supplies `JANITOR_GOOGLE_REVOKE_EXECUTABLE` from its pinned
official-SDK helper package; tokens never appear in its process arguments or a
temporary credential file.

`nixosModules.google-token` is also usable by the private Azure host. Its
`services.emailjanitor-google-token.configuration` contains only the official
Google external-account **metadata**, not a private key or token. A root-owned
SDK helper refreshes `/run/emailjanitor-google-token/token.json` every minute;
the app group can read the atomic, short-lived file but cannot change it. The app
reads a fresh file for each resolution rather than a boot-time credential copy.
The AWS reference still uses only its instance role for Bedrock and SES/S3/SQS.

Setting `services.emailjanitor.publicHostname` enables the reference Nginx/ACME
HTTPS proxy; the app itself listens on loopback port 4000. This hostname must
match `JANITOR_PUBLIC_URL`, DNS must already point to the host, and the reviewed
cloud firewall must separately allow HTTP/HTTPS before certificate issuance.
The proxy **overwrites** `X-Real-IP` with the socket remote address and removes
forwarded chains. It disables dedicated-host access/error request logs so OAuth
code/state, cookies and chat content do not enter proxy logs. Null leaves public
web access closed for the SSH pilot; this module performs no DNS/cloud changes.
