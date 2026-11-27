# Email Janitor implementation plan

Status: implementation started; infrastructure not provisioned.
Date: 2026-11-26.

## Product and boundaries

Email Janitor marks unwanted email Done while people keep using Gmail,
Superhuman, or their preferred email client. Done means removing Gmail's INBOX
label from the reviewed messages. Do not delete, move to Spam, mute, or change
read/unread state.

Two deliverables share the same engine:

- **MIT project:** an Elixir library and a complete single-user service. One
  user, multiple Google inboxes, all cleanup/conversation/digest features, no
  suppression cap, no multiuser tenancy or billing. Supported deployment is
  NixOS on AWS, provisioned with OpenTofu, with SOPS-managed deployment secrets.
- **Private SaaS:** emailjanitor.net, an Elixir application running on Azure,
  using Azure AI and AWS SES for email. It embeds the MIT library and adds
  multiple users, isolation, Google login/account groups, subscriptions, and
  billing. Do not build a separately maintained cleanup implementation.

Google means Gmail and Google Workspace for v1. Both deployments need a Google
Cloud project/API credentials; GCP hosts Gmail notification resources, not the
application. Janitor's own email transport is AWS SES, not a Gmail mailbox.

Self-hosters use their own AI credentials and select supported provider adapters.
Use established SDKs/clients; do not reimplement provider authentication or agent
protocols. Customers of the SaaS need no AI credentials or CLI subscription.

## Agreed user journeys

1. Sign in with Google, detect the browser timezone, and connect inboxes. Begin
   with new arrivals after connection, not the existing inbox. Any connected
   Google identity can subsequently log in to the same account group and paid
   subscription. Block linking an identity already in a different group; do
   not merge groups automatically.
2. On arrival, classify and promptly mark qualifying messages Done. Start with
   unsolicited sales pitches and the existing Janitor safeguards. A notification
   from Superhuman can arrive before cleanup; v1 does not attempt to prevent it.
3. Free SaaS marks at most two messages Done per connected account per local
   calendar day. The allowance resets at local midnight. Extra matches stay in
   the inbox; they never roll into a later day's free allowance. Explicit cleanup
   requests also respect this cap. Restoring a mistake and correcting instructions
   remain available without a subscription.
4. Paid SaaS costs **$3 per user per month through Stripe**, covering unlimited
   connected Google accounts, with no annual plan. Upgrade rechecks and cleans
   all previously identified unwanted messages still in the inbox using current
   instructions, while preserving manual restores and other safeguards. Cancellation
   takes effect at the end of the paid billing cycle.
5. At 9 p.m. in the saved browser timezone, send one digest per inbox to that
   inbox, only when it has new reportable activity. Keep it minimalist: sender
   and subject of messages marked Done, plus newly identified free-plan matches
   that would have been marked Done with the $3/month upgrade. List each extra
   only once; old digests are snapshots, not a live backlog list. The first digest
   explains that replying teaches Janitor. Use the user's approved product wording;
   final layout/copy is an implementation deliverable, not another settings flow.
6. Replies to digests, direct emails, forwarded examples, and website chat reach
   the same assistant workflow. Interpret corrections conversationally and distil
   them into an additional or modified prompt instruction. Act immediately on clear
   requests, always explain what actually changed, and allow further correction
   or undo. Ask only when a request cannot be resolved safely from context; do not
   require users to fill in fixed sender/domain/scope rules.
7. SaaS sends from janitor@emailjanitor.net. Legitimate human senders without an
   account receive signup instructions. Self-hosters choose a dedicated domain or
   subdomain; optional delegation under emailjanitor.net is a convenience, not a
   dependency for using their own domain. Domain delegation points directly at
   their own SES infrastructure; do not introduce a SaaS mail relay for self-hosters.
8. Website application surfaces are **connect accounts, chat, and billing**. Add
   connection/pause/error state within those surfaces, not a separate dashboard,
   email client, per-email chat UI, prompt editor, or rule-builder UI.
9. Catch up on messages received during service outages or temporary authorization
   failure. Disconnect stops future processing without restoring previous cleanup.
   Revoke the Gmail authorization and delete its stored credentials. Release that
   identity's group membership unless it is the last login identity; keep the last
   identity for login/billing only, without Gmail access. Group deletion is separate.

### Precise defaults needed for implementation

These resolve technical boundaries without adding configuration screens:

- A free unit is one successfully marked-Done Gmail message, not a thread, model
  call, retry, or failed API call. For free-plan automatic cleanup, the pre-mutation
  recheck must show that every current INBOX message in the conversation is eligible
  for this action and all fit the remaining allowance. A kept, restored or previously
  cap-excluded message prevents partial cleanup of the conversation; leave the new
  match pending and list it once too. Paid cleanup remains per message. Mutate exact
  reviewed IDs, not the thread. A new reply racing after that check is independently
  assessed, never swept away; Gmail offers no atomic thread-check-and-mutate operation.
- Quotas use the time of the actual action, including outage catch-up, not expired
  allowances replayed from old arrival dates. Extra matches already excluded by
  the cap remain pending until paid; catch-up cannot bypass this rule.
- Digest scheduling and quota reset are different boundaries. At 9 p.m., send
  activity not yet reported; arrivals after the cutoff appear in the next digest.
  Never drop late-evening activity or repeat extras to force calendar-day wording.
  Recover one pending digest after downtime instead of sending an email per missed
  day. Respect daylight-saving changes using an IANA timezone, not a fixed offset.
- A restore does not reset the free allowance or let users repeatedly recycle
  two free slots. Protect the restored message from automatic re-archiving.
- Only pause/block the affected inbox on a connection failure. Keep other inboxes
  processing. Show why it paused and how to reconnect, without claiming cleanup
  succeeded. Recovery from an outage or temporary authorization failure catches up
  from its original baseline. A deliberate disconnect is different: reconnecting
  sets a fresh baseline and does not process mail received while disconnected.
  Reconnecting to the same group preserves its minimal action history, learned
  instructions, restore protections and pre-disconnect pending candidates. Those
  candidates never gain later free slots; paid cleanup can recheck them after access
  is restored. Linking to a different group transfers none of the old group's state.
  Retaining old-group metadata never grants access to credentials from the new group.

## Existing assets to reuse

Source of behavior: workstation/email-janitor/sweep.py, prompt.txt, README.md, and
test_sweep.py. Preserve their prior-correspondence checks (including parent-domain
matching and exact addresses for shared providers), SENT/DRAFT protection, careful
relay identity handling, conservative uncertain-message behavior, pre-mutation
rechecks, exact-message restoration records, and manual-restoration protection.

Separate the generic default from Andrei's learned instructions. "Question" in a
subject, podcast/research preferences, and Fogbender-specific subjects belong to
his profile; do not silently impose them on every customer. Own-organization-domain
protection is generic: derive it per Workspace inbox, excluding shared providers
such as gmail.com. Known relay addresses are structured, operator-controlled
per-inbox identity configuration, not model-editable prompt text; migrate Andrei's
hello/support relays at cutover. Sanitized mistakes become regression fixtures.
Never copy live mailbox bodies or credentials into the MIT repository or fixtures.

TNA inspiration, read-only: service/mix.exs, AGENTS.md, infra/nixos/README.md,
infra/aws/README.md, and infra/azure/README.md under ~/src/tna. Reuse the principles
of small functional modules, OTP supervision, Ash where domain actions need it,
PostgreSQL, Oban jobs, Nix builds, SOPS, and separate host/app deployment. Do not
copy its business code, deployment controller, private credentials, Azure resource
identifiers, paid vendored libraries, or unrelated blue/green machinery.

## Repository and application structure

Create separate local repositories, then separate remotes with matching visibility:

- ~/src/emailjanitor (fogbender/emailjanitor): public-ready MIT source, library, runnable single-user host,
  Nix development/release configuration, AWS/GCP OpenTofu, setup commands, and docs.
  Keep it local/private until the source and history have been checked for secrets.
- ~/src/emailjanitor-saas (fogbender/emailjanitor-saas): private Phoenix/LiveView application, tenant/account
  group management, login, billing, Azure/AWS infrastructure, marketing site, and
  deployment configuration. Depend on a pinned version of the MIT package.

Start the setup CLI in Elixir to share validation/configuration with the service
and avoid a second language before needed. A small Rust launcher is justified
only if a standalone bootstrap binary materially simplifies installation; it
must delegate configuration/domain behavior rather than duplicate it. This is a
reversible implementation choice, not a prerequisite to engine development.

The MIT package exposes a Janitor instance with explicit configuration and
storage/transport/model dependencies. It has no users table, billing, tenant
discovery, cross-user routing, or global account credentials. Its single-user
host runs one instance with its own database. Its storage boundary must permit
the SaaS host to isolate instances without patching the library.

The SaaS host owns group membership and scope. Every API request, assistant tool,
background job, storage call, Gmail credential lookup, and mail conversation is
bound to its group and inbox. Choose one enforceable storage design in the first
architecture slice: host-supplied scoped repository with database enforcement,
or per-group database schema. Prove adversarial cross-group access fails before
adding real users. Avoid a global GenServer or environment-selected active user.

Use Ash resources/actions with explicit types where useful, Oban for durable jobs,
Phoenix/LiveView for the minimal host UI, and maintained provider libraries. Keep
classification and prompt reasoning distinct from the executor that is allowed
to mutate Gmail. The model never receives OAuth secrets, cloud credentials, arbitrary
shell/network tools, or authority to email arbitrary destinations.

## Durable data and privacy

Persist only what is necessary:

- Inbox identity, encrypted rotating OAuth credentials, connection baseline,
  Gmail history cursor/watch expiry, timezone, and connection status.
- One versioned user preference section per single-user instance / SaaS account
  group, with provenance and reversible edits. Include inbox identity in model
  context; express account-specific instructions naturally in that preference text.
  Do not silently apply Fogbender-specific instructions to unrelated inboxes.
- Gmail message/thread IDs, minimal sender/subject metadata for digests, reviewed
  fingerprints, decision category/confidence, pending candidates, manual-restore
  protection, exact action IDs, intent/reconciliation status, and timestamps.
- Message references, bounded sanitized action summaries, and assistant responses
  that explain actual actions. Email-derived conversation memory is distilled
  instructions, not stored incoming email transcripts. Apply the same body-removal
  rule when somebody pastes or forwards an email into website chat.
- Daily quota reservations/results, digest delivery records and listed IDs,
  inbound delivery deduplication IDs, and outgoing response/outbox state.
- SaaS-only users/groups/verified identities, Stripe customer/subscription state,
  entitlement validity, and idempotent webhook records.

**Never retain full email bodies in application databases, logs, job arguments,
chat history, traces, error reports, backups, or classification caches.** Fetch
Gmail content on demand, parse/classify in memory, and discard it. Instructions,
summaries, and model errors must not become a backdoor for quoted full bodies.
Disable request/body logging and model-payload tracing throughout the stack.
Enforce this from Phase 1, not only in a final log scan: redact content wrapper
inspection, sanitize SDK/parser exceptions before they reach Logger/Oban, and keep
raw text out of LiveView state, crash reports and persisted job errors. A wrapper
alone is insufficient if an SDK exception includes its raw input. Fault-injection
tests must exercise parser, model, transport and process crashes with sentinel
content and verify metadata-only errors; retain useful error IDs/stack locations.

Encrypted temporary transport storage is allowed for inbound feedback. SES writes
to a dedicated S3 spool encrypted server-side with a dedicated KMS key (SSE-KMS);
do not enable SES receipt-action client-side encryption, which would require a
separate encryption-client implementation. Scope SES bucket-write and app-read/KMS
permissions explicitly. Jobs carry object references only. Delete after processing.
Add a short maximum processing lifetime and a cleanup sweeper for
abandoned/failed objects; lifecycle expiration is a fallback, not prompt deletion.
No object versioning, replication, or backups for that spool. Document actual
transport/provider retention honestly, including retries and failure cleanup.
Do not promise upstream cloud/model providers have zero retention without checking
their selected services, deployment settings, and agreements.

Classify Gmail mail by refetching Gmail, not by sending cleaned inbox bodies through
SES. Fetch attachments only if a supported feedback workflow actually needs them;
do not build attachment browsing or remote-link following in v1.

Deployment secrets use SOPS and cloud KMS; live OAuth token rotation uses encrypted
runtime storage. Keep runtime encryption keys out of the Nix store, OpenTofu
plaintext outputs, logs, and command arguments. Protect OpenTofu state with cloud
encryption and scoped access; SOPS alone does not protect secrets in state.

## Integration contracts

### Gmail and Pub/Sub

Use Gmail API OAuth with minimum required scopes. Set a baseline at first
connection; process new arrivals, plus missed arrivals after that baseline.
Pub/Sub is a change signal: fetch Gmail history, checkpoint durably, and reconcile
if history has expired. Reconciliation must preserve the initial baseline, caps,
pending candidates, and manual-restoration records. Include relevant label changes
so restoring an archived message is observed. Renew watches before expiry and
perform periodic reconciliation because notifications are not an email store.

Self-hosted AWS and Azure SaaS can consume GCP Pub/Sub through authenticated pull
workers. Use short-lived cloud identity/federation where supported rather than
copying broad service-account keys. A Google Internal audience cannot span unrelated
organizations; self-hosted setup must guide the appropriate OAuth configuration.
External OAuth apps in Testing can issue refresh tokens that expire after seven
days for Gmail scopes. Validate audience/publishing mode during setup. Single-user
personal-use exceptions or a suitable Internal organization app may avoid public
verification; do not assume that fewer than 100 users exempts a hosted SaaS pilot.
Use an eligible configuration and explain unavoidable authorization warnings/admin
approval. Discover the verification process early; submit the near-final deployed
SaaS for the assessment that actually requires that app, then await approval before
general availability. Do not hide weekly token expiry behind a successful setup test.
Public SaaS launch depends on Google OAuth verification for required Gmail scopes
and any applicable restricted-scope security assessment. Discover requirements and
costs early; don't treat successful private development login as launch approval.

Before removing INBOX, refetch/check exact reviewed message IDs, contact history,
SENT/DRAFT state, manual restores, effective instruction version, and entitlement.
Record action intent, history cursor, exact IDs and quota reservation atomically.
Reconcile timeouts using ordered Gmail history since that intent, not just current
labels. INBOX removed then re-added means an action occurred and mail was restored:
count the slot and protect the message. An observed removal with no later restore
also settles the reservation, conservatively, even if its actor is unknowable.
Retry only when complete available history proves no removal, after rechecking all
guards. If evidence expired, retain an unresolved reservation and leave mail alone;
never retry merely because it is currently in INBOX. Surface unresolved actions
truthfully. No distributed transaction with Gmail is assumed. Preserve other labels.
Skip Janitor's own outgoing digest/response messages before classification using
recorded send IDs and verified sending identity/authentication, not a spoofable
From/header alone. They never consume cleanup quota.

### Models and assistant actions

Start with one small Azure deployment for SaaS and the same adapter path for the
self-hosted reference installation. Add at least one direct OpenAI or Anthropic
API adapter before the AWS self-host release, so it does not require Azure.
Use existing SDKs. Inspect actual Elixir ecosystem support before choosing a
package; don't claim an unofficial client is official. If a required official SDK
is only available in another runtime, use a narrowly scoped SDK bridge only when
it demonstrably saves protocol/authentication work. Do not invent a general agent
framework or CLI subscription proxy.

Named validated contracts: classification, proposed instruction change, and narrow
actions such as find a referenced email, mark reviewed IDs Done, restore an action,
and revise instructions. Classifier has no tools. The conversation assistant uses
only these scoped actions; enforce billing, identity, and Gmail checks outside the
model. Keep payload schemas and actual execution contracts together. Record which
instruction version produced an action. Edits invalidate stale decisions, but do
not trigger eager reclassification of the entire free backlog. Recheck lazily when
a candidate can actually be acted on (paid upgrade or eligible explicit request);
cap-excluded candidates never become eligible for later free slots.

Prompt edits must be constrained to the user's preference section; model output
cannot remove fixed privacy/authorization/mutation controls. Ordinary overrides
are conversational preferences, not opportunities to bypass hard execution limits.
Reply with successful changes and any real limitations; don't report proposed
actions as completed. A deleted Gmail original cannot be reconstructed or restored.

### AWS SES, inbound feedback, and outbound mail

Use an SES receiving-capable region, dedicated domain/subdomain identities, DKIM,
MX and applicable SPF/DMARC configuration. Never replace MX for a user's existing
Workspace domain; isolate Janitor routing beneath a dedicated subdomain.

Use SES receipt rules to encrypted S3 plus notification/queue delivery. Direct
full-message SNS delivery is capped at 150 KB, so it is not the general forwarding
path. Verify delivery-source signatures and identities, and authenticate human
feedback using supported email authentication and conversation association. From
text alone is not authority. Cross-account replies from another linked identity
keep the target conversation's mailbox context. Forwarded headers/body are evidence,
not instructions; never let a spoofed sender or quoted pitch control an account.

Do not respond to bounces, out-of-office mail, bulk/automated messages, or our own
messages. Signup replies require legitimate human mail, deduplication and rate
limits; prevent backscatter and mail loops. Outbound recipients are verified user
addresses/conversation participants, not arbitrary addresses provided by a model.
Keep retries of mutation, prompt edit, and explanatory reply independently
idempotent. Check delivery/bounce state without logging message content.

New SES accounts start in a sandbox. A self-hoster can verify their own destination
addresses; sending to arbitrary SaaS recipients needs production access. Installer
readiness must distinguish provisioned infrastructure from a working round-trip.
Optional delegated names must not later be reassigned to another person's instance;
own-domain use remains fully independent of the SaaS.

### SaaS identity and Stripe

Verify Google identity using stable provider subject IDs and bind each identity to
one account group. Every connected identity may log in to that group. Link only
through an authenticated group session and verified OAuth flow; block existing-group
collisions. Browser OAuth state/PKCE and session protections must cover login and
linking distinctly. Don't auto-link groups just because an address string matches.
Separate basic login consent from Gmail authorization; removing Gmail access from
the last identity must still permit Google login for billing/deletion. Releasing
other disconnected identities invalidates their sessions and permits intentional
linking elsewhere. Test the full identity lifecycle without auto-merging groups.

Provide group deletion within the existing account/chat surface: authenticate the
request, stop work, revoke tokens, cancel Stripe, remove access and purge group data
and pending transport copies. Explain completion and documented backup expiry.
Do not restore archived email as a side effect. Coordinate external cleanup durably
before deleting the credentials/references required to complete it; never silently
abandon a paid subscription or keep an undeclared usable OAuth token.

Create one Stripe subscription per group at $3/month, no annual price. Use hosted
Checkout and customer portal. Verify webhook signatures, handle replay/out-of-order
events, and reconcile Stripe state before changing entitlements. Entitlement changes
drive the same library policy boundary as direct cleanup requests. Activation starts
bounded jobs over all pending candidates; it does not bypass safeguards or reclassify
every old inbox message. Cancellation retains paid access through period end.
Handle unresolved payments without claiming an unpaid invoice grants unlimited
cleanup; reconcile paid-through state and expose billing recovery in the existing UI.

## Implementation sequence and acceptance gates

### 0. Reviewed plan and external prerequisites

- Review this plan with Claude Opus 5.5 and resolve actionable findings before code.
- Inventory available cloud accounts, domain control, model quota, and Gmail OAuth
  verification requirements read-only; use Janitor-specific resource namespaces.
- Choose/pin minimal existing Elixir/provider dependencies and tenancy storage design;
  document the actual decision in the new repositories rather than leaving it vague.
- Do not alter the running Fogbender Janitor, TNA, shared auth profiles, or unrelated
  workstation changes. Never use real inboxes to generate test fixtures.

Gate: reviewed plan, a concrete isolation contract, and identified external launch
dependencies. External approvals may proceed in parallel with local implementation.

### 1. MIT engine and behavior parity

- Create MIT repository, Nix dev shell, OTP application, persistence migrations,
  typed actions, provider boundary, and single-user host with one configured identity.
- Port generic safeguards and sanitized regression examples from the Python Janitor.
  Add Andrei's current preferences only to his eventual instance configuration.
- Implement classifier, instruction versions, exact-ID action intents, restore
  protection, Gmail fake adapter, durable retry/reconciliation, and content-safe
  exception/logging boundaries with sentinel-content failure tests.

Gate: meaningful tests demonstrate keep/Done outcomes, prior contacts/shared domains,
relay identity, sent/drafts, changing threads, HTML parsing, manual restores,
timeout reconciliation, and body-free persistence. Existing production timer remains
untouched. One live model evaluation uses synthetic/sanitized messages, not a real
inbox, and measures cost and classification quality.

### 2. Single-user Google connection and catch-up

- Add OAuth account connection, multi-inbox configuration, token rotation, Pub/Sub
  workers, initial baseline, history renewal/reconciliation, and backoff.
- Add a minimal isolated development OpenTofu stack for the GCP topic/subscription
  and auth wiring; Phase 4 reuses these modules rather than provisioning it later.
- Build standalone account-connection UI. Conversation UI arrives with Phase 3's
  workflow. No SaaS billing code or cap in the MIT host.

Gate: dedicated test accounts prove only new arrivals are processed, multiple accounts
remain correctly routed, read/unread survives, and recovery after restart/history
loss neither skips post-baseline mail nor reprocesses manual restores.

### 3. Conversational corrections and daily digest

- Implement website and email entry points to one workflow, context resolution,
  immediate typed actions, distilled prompt updates, undo, and explanatory responses.
- Add SES receive/send transport, encrypted spool cleanup, automatic-mail filtering,
  durable outbox/deduplication, and per-inbox 9 p.m. digest scheduling.
- Extend the isolated dev OpenTofu stack with an SES test receiving subdomain,
  SSE-KMS spool and queue, test recipient verification and a real round-trip.
  Build the standalone chat UI against the now-implemented conversation workflow.
- Add and evaluate the first direct OpenAI/Anthropic API adapter before Phase 4.
- Keep digest simple; no per-email assistant surface, live email cache, or rule builder.

Gate: exercise digest reply, forwarded pitch, website correction, undo,
spoofed/automated mail, large forwards, failed response
delivery, prompt changes during queued work, DST, and late-evening digest activity.
Scan database rows, job arguments, logs, traces, errors and backups for body leakage.
Verify abandoned spool objects are deleted, not just successful-path objects.

### 4. AWS self-host deployment and documentation

- Reuse the validated dev integration modules. OpenTofu: state/bootstrap, network,
  NixOS-capable compute, PostgreSQL, KMS/SOPS,
  SES/domain DNS/spool/queue, IAM, and GCP Pub/Sub/API wiring. Prefer one small
  instance and an explicit backup/restore story over elaborate orchestration.
- Setup commands validate credentials/model endpoint, guide unavoidable Google/SES
  steps, run receiving/sending/Gmail event checks, then enable processing.
- Package app as a pinned Nix release and systemd service; routine app deployment
  does not require rebuilding/rebooting the host. Document upgrades, migrations,
  credentials/encryption/state backup, reconnect, uninstall, and own-domain routing.
- Document optional delegation; do not build an automated public subdomain allocation
  service as a launch dependency. Never add a hosted mail relay for self-hosters.

Gate: a fresh isolated AWS install can connect two test inboxes, classify synthetic
arrivals, send/receive a digest conversation, restart, restore from backup, and remove
its infrastructure without changing existing mail-domain routing. MIT license and
public-source/history review are complete before publication.

### 5. Private SaaS host, identity, quotas, and billing

- Create private repo consuming the same versioned MIT engine. Implement tenant
  storage isolation first, then Google identity groups and account connection.
- Add the minimal website/application, Stripe monthly billing, per-account local-day
  quota policy, once-only extra digest section, and upgrade backlog processing.
- Test concurrent jobs against shared quota, retries around midnight/payment events,
  candidate changes after feedback, group-link collisions, and login via every
  connected account. Explicit cleanup requests use the same entitlement executor.
  Test unknown-human signup replies, last-identity disconnect, token revocation,
  reconnect/relink, session invalidation and full group deletion including billing.
  Prove deliberate-disconnect gaps are skipped, outage gaps are caught up, and
  cross-group relinking cannot inherit old metadata or reuse new credentials there.
  Test free-plan threads containing kept, restored or previously cap-excluded INBOX
  messages: a new match stays pending, uses no quota, appears once in the digest,
  and never uses a later day's free slot. Also test a new reply racing the exact-ID
  mutation is left untouched, and paid per-message cleanup remains independent.

Gate: two groups cannot read/mutate each other's inboxes, tokens, instructions, jobs,
chat, or billable state. A free-plan five-message scenario marks exactly two Done
and lists three once; the next day does not use free slots on those three.
Upgrade cleans eligible pending messages;
restores remain protected; cancellation downgrades only at paid-through end.

### 6. Azure SaaS deployment and real pilot

- OpenTofu: dedicated Azure app/network/PostgreSQL/identity/model resources plus
  AWS SES mail infrastructure and GCP notification resources. Use Janitor-specific
  resource groups/accounts and least-privilege identities, not TNA credentials.
- Deploy emailjanitor.net with TLS, monitored jobs/connection health, encrypted
  backups, minimal metadata-only telemetry, and tested temporary-spool expiration.
- Complete Google/SES launch gates before general signup. Keep private pilot
  allowlisted while approvals are pending. Finalize truthful privacy/retention terms.
- Pilot on dedicated accounts first, then Andrei's approved inboxes. Avoid two
  writers: pause the old timer for a mailbox only at its explicit cutover, transfer
  minimal action/manual-restore history and learned instructions, record a baseline,
  and verify before enabling the replacement. Rollback disables the new writer
  before resuming the old one; never run both as a fallback.

Gate: actual user journey from Google connect through new-mail cleanup, 9 p.m.
digest, email correction, website chat, free cap, paid upgrade, and cancel is
exercised. Record what was implemented, tested, deployed, and observed by the user
separately. Measure per-account model/infra/email costs against $3/month without
assuming credits last forever. Keep an operator pause/rollback path.

## Verification and review workflow

Normal tests use fake providers and isolated Postgres/cloud test resources. Live
AI tests use dedicated evaluation deployments and sanitized examples. No test email
goes to unrelated recipients. Test real transport/cross-cloud boundaries before
calling a mocked pipeline deployed or ready.

For every code change, run relevant checks, commit scoped changes, then run the
other coding agent's local review to no actionable findings before push/PR. For
Codex work use Claude Opus 5.5 with the required structured streaming review.
For a PR also complete the cloud Codex review gate after local review; check all
three GitHub verdict surfaces described in the user's AGENTS instructions.
Keep full review logs out of repositories and exclude secrets from review context.

## Explicit non-goals for v1

No Outlook, new email client, scheduling assistant, arbitrary send-as-user tool,
annual pricing, customer CLI subscription authentication, configurable digest
schedule, per-email chat UI, self-hosted multitenancy, account-group merging,
old-inbox bulk cleanup on first connection, body archive, custom provider protocol,
general-purpose deployment controller, or parallel Python/Elixir mailbox writers.

## Reference constraints

- Gmail changes and watch renewal:
  https://developers.google.com/workspace/gmail/api/guides/push
- Gmail history recovery:
  https://developers.google.com/workspace/gmail/api/guides/sync
- Google OAuth audience restrictions:
  https://support.google.com/cloud/answer/15544987
- Gmail restricted scopes:
  https://developers.google.com/workspace/gmail/api/auth/scopes
- SES direct-message SNS size limit:
  https://docs.aws.amazon.com/ses/latest/APIReference/API_SNSAction.html
- SES sandbox/production access:
  https://docs.aws.amazon.com/ses/latest/dg/request-production-access.html
- SES encrypted temporary receipt storage:
  https://docs.aws.amazon.com/ses/latest/dg/receiving-email-action-s3.html
