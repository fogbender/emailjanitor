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
notifications containing object references. It does not create a Gmail inbox,
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

This first template supports SES receiving in `us-east-1`, `us-west-2`, or
`eu-west-1`. Sending identity verification, DKIM and sandbox status are regional.
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
`ssh_source_cidr`. Do not put OAuth tokens/model API keys into OpenTofu variables
or user-data: those would persist in state and instance metadata.

## NixOS runtime and secrets

Import `nix/module.nix` into the NixOS image and supply the built Elixir release:

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
one received feedback message through SES→S3→SQS; immediate spool deletion after
success and bounded deletion after failure; a response delivered back to the test
inbox. Infrastructure output `ready_for_processing` deliberately remains false.

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
