# Self-host infrastructure

This is an **unapplied infrastructure foundation**, not a working installer or
deployable Email Janitor release. The Elixir application is still being built.
The supported self-host platform is AWS. SaaS hosting belongs to the separate
private repository and runs on Azure, also using AWS SES for mail.

## What is provisioned

`selfhost/` composes one small EC2 host, an isolated VPC, encrypted root disk,
IMDSv2, restricted SSH, a least-privilege instance role, mail transport, and Google
notification resources. It requires an existing **NixOS AMI built with the real
application release**; it does not rewrite an existing server or build an AMI.
The database runs locally through the NixOS module and is not exposed over TCP.
There is no public app port until authentication and TLS are implemented.

`modules/mail/` provisions SES sending/receiving identity and DKIM, a dedicated
Route53 zone, an SSE-KMS encrypted temporary S3 mail spool, and encrypted SQS
notifications containing SES receipt metadata and object references. The S3
action's optional SNS notification excludes MIME content; delivery headers may
occur transiently in SNS/SQS and must be whitelisted before database persistence.
Only the exact SES delivery role may publish to the encrypted topic, and only
that topic may inject into the queue (including an explicit deny for other
SendMessage grants). Both queues retain metadata for ninety minutes (the one-hour
processing TTL plus a delivery margin). It does not create a Gmail inbox,
run an SMTP server, relay through Email Janitor SaaS, or retain a mail archive.
SES direct-body SNS delivery is deliberately avoided because its 150 KB limit
breaks ordinary forwarded HTML messages. No SES receipt-action encryption is
enabled: that uses a separate client encryption format. Normal S3 SSE-KMS is used.

The module does not enable spool versioning, replication or backup. Exclude its
`EmailJanitorDataClass=temporary-mail-spool` tag from any account-wide backup policy.
The application must delete
objects immediately after processing and sweep abandoned/error objects within a
short bounded lifetime. S3's one-day lifecycle is a slower emergency fallback,
not an implementation of immediate deletion. A failed notification must be
reconciled from the spool; the queue itself contains no message bodies.

`modules/gmail_notifications/` enables Gmail and Pub/Sub APIs in an **existing
Google Cloud project**, gives Gmail permission to publish, and creates a dedicated
consumer service account with access only to its pull subscription. It does not
create an OAuth client or perform mailbox consent. It also provisions workload identity
federation restricted to the AWS runtime role, without service account key files.
The setup CLI must generate the non-secret external-account credential
configuration from the provider/service-account outputs for the runtime SDK. OAuth audience must support the intended Google accounts. An External
Testing app can expire Gmail refresh tokens after seven days.
The external-account configuration must enable IMDSv2 (for example,
`gcloud iam workload-identity-pools create-cred-config ... --aws --enable-imdsv2`),
because the EC2 instance rejects tokenless metadata access.

## DNS and account boundaries

Choose a dedicated subdomain such as `janitor.example.com`, or a new dedicated
domain. This code creates a **new zone** and returns its name servers; it never
changes existing parent-zone MX records. Delegate that subdomain at its parent
DNS provider after reviewing the output. Do not replace the existing nameservers
of a domain containing other mail/web services with this zone.

An optional name under `emailjanitor.net` can be delegated manually to those same
name servers. It points directly to your AWS account, with no SaaS mail relay.
Your own domain remains independent. Retired delegated names must not be assigned
to another user, because old replies could expose data.

SES has one active receipt rule set per AWS account and region. The default
`activate_receiving = false` creates Janitor's set **without replacing an existing
active set**. Before activation, inspect the regional receiving configuration;
use a dedicated account/region or integrate the Janitor rule into an intentionally
managed shared set. Setting the switch true is an explicit regional replacement,
and must not be done blindly. Removing an active-set resource also changes regional
receiving state; plan that operation while stopping the service.

The reference deployment uses `us-east-1` for SES and Bedrock. Self-host AI uses
Bedrock through the EC2 role, with no Azure/OpenAI/Anthropic API key setup. The
default is the regional `amazon.nova-micro-v1:0` model; runtime IAM grants only
`bedrock:InvokeModel` for the configured foundation-model ARN. Streaming and
cross-region inference profiles are outside this initial reference. Keep the
NixOS `bedrockModelId` equal to OpenTofu `bedrock_model_id` when changing it.
Sending identity verification, DKIM and sandbox status are regional.
Self-hosting can initially verify its own destination inboxes in the SES sandbox.
Arbitrary signup replies and SaaS recipients require production sending access;
AWS approval is external to OpenTofu.

## Plan, do not apply until the application is ready

From a source checkout with Nix installed:

```sh
nix develop
tofu -chdir=infra/selfhost init -backend=false
tofu -chdir=infra/selfhost validate
tofu -chdir=infra/selfhost test
nix-instantiate --eval --strict --json nix/check-module.nix
```

The native OpenTofu tests mock AWS/Google providers. They do not use cloud
credentials or create resources. The provider versions and downloaded checksums
are pinned in `selfhost/.terraform.lock.hcl`. Before a real deployment, configure
encrypted remote state with locking; do not commit state or `.tfvars`. SOPS does
not itself encrypt OpenTofu state. This template deliberately has no account IDs,
credentials, private domain names or company resource groups embedded in it.

Supply `name`, `mail_domain`, `google_project_id`,
`nixos_ami`, `ssh_key_name`, and a restricted
`ssh_source_cidr` (canonical /24–/32; normally your operator IP /32).
Do not put OAuth tokens into OpenTofu variables
or user-data: those would persist in state and instance metadata.

## Gmail poison-notification handling

The Gmail pull subscription forwards repeatedly unacknowledged notification hints
to a private dead-letter topic after approximately five delivery attempts. Pub/Sub
counts these attempts on a best-effort basis; this is not an exact retry cap.
The dead-letter topic and its persistent inspection subscription retain hints for
one day. Hints contain mailbox/history metadata, never full email content. The
application must still acknowledge deliberately disconnected identities only
after verifying that state, and durably coalesce valid hints before acknowledgement.
Temporary Gmail authorization failures belong to the affected inbox's durable
recovery state rather than an endless notification retry.

The pinned `google-beta` provider explicitly generates the Pub/Sub service
identity. That service agent receives Publisher only on the dead-letter topic
and Subscriber only on the source subscription, as required for forwarding and
acknowledgement. The Janitor consumer retains only its existing source-subscription
grant; it gains no project-wide or dead-letter read permission. An operator can
inspect `gmail_dead_letter_subscription` with a separately authorized identity.
Monitor its backlog/forwarded count and verify actual forwarding before launch;
native mocked plans cannot prove provider delivery or IAM propagation timing.

## NixOS runtime and secrets

Add a locked Email Janitor flake input and include its `nixosModules.default`
in the image's module list. That export supplies the release built with Email
Janitor's pinned nixpkgs, independently of the host's nixpkgs; see
[release packaging](../docs/release-packaging.md).

For a lower-level path import, explicitly supply that reviewed flake package:

```nix
{
  imports = [ /path/to/emailjanitor/nix/module.nix ];
  services.emailjanitor = {
    enable = true;
    package = emailJanitorRelease; # Must provide bin/email_janitor.
    environmentFile = "/run/secrets/emailjanitor/environment";
  };
}
```

Use SOPS with your cloud KMS or operator age key to manage the encrypted source
secrets. The host's chosen SOPS integration must decrypt that environment file
at boot, root-readable only, and restart `emailjanitor.service` on rotation.
Only the runtime path is in Nix configuration. Do not use a Nix path literal
for decrypted secret contents. Grant KMS/secret access only to the intended host;
this foundation does not provision a blanket secrets-decryption role.

The service has its own system user, private state directory, Unix-socket PostgreSQL,
automatic restart, and disabled BEAM/core crash dumps. Application error handling
must independently avoid email content in logs and errors. Installing the service
does not prove the binary is a complete product or configure Google/model credentials.

## Readiness, backup, and removal

Do not enable automatic cleanup until an actual test account proves all of:
Google profile identity and OAuth refresh; a new Gmail/PubSub event; a synthetic
model classification; SES verified identity/DKIM and permitted recipient sending;
one received feedback message through SES→S3-action SNS→SQS; immediate spool deletion after
success and bounded deletion after failure; a response delivered back to the test
inbox. Infrastructure output `ready_for_processing` deliberately remains false.
Also inspect Bedrock's account/region invocation-logging configuration before
processing real inboxes: text invocation logging records full model input/output
in S3 or CloudWatch. It is disabled by default; a preexisting shared-account
setting must not be silently changed by this deployment. Use an account/region
without text invocation logging for this service. See the
[AWS logging documentation](https://docs.aws.amazon.com/bedrock/latest/userguide/model-invocation-logging.html).
The receiving worker must reject arbitrary S3 `ObjectCreated`/`s3:TestEvent`
payloads as provenance and ignore/delete SES's
`AMAZON_SES_SETUP_NOTIFICATION` objects instead of treating setup probes as human
feedback. Test those cases before declaring the transport ready.

Back up PostgreSQL state (instructions, actions, restore protections and cursors),
runtime token encryption keys, and SOPS recovery material using encrypted backups.
Do not back up the temporary email spool. Test restore with workers paused, then
resume from durable cursors; do not start competing copies against one inbox.
PostgreSQL initially lives on the instance's encrypted root disk. The instance
has `prevent_destroy = true` so changing its AMI or another replacement field
cannot silently erase that state. Update routine application/NixOS configuration
on the existing host. An intentional host replacement requires a tested backup,
migration to the replacement, and deliberate removal of that lifecycle guard.

Before uninstalling, stop the service and revoke Google authorizations. Preserve
or explicitly erase durable user state according to your intent; previous Gmail
Done actions remain in effect. Drain/delete temporary spool objects before
`tofu destroy`; the bucket deliberately refuses force-destroying mail. Review DNS
and SES activation removal separately. The module never reverses previous Gmail
actions or touches a user's original mail-domain routing.
