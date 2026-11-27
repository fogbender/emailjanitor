# AWS single-user setup

The setup CLI prepares local configuration. It does not apply OpenTofu, start
cleanup, connect Google accounts, exchange cloud credentials, or send mail.
The supported self-host path is NixOS on AWS with Bedrock in `us-east-1`.
See [infrastructure](../infra/README.md) for the deployment and DNS boundaries.

Run the packaged CLI with `nix run .#setup -- ...`, or from a source checkout:

```sh
nix develop --command mix emailjanitor.setup --help
nix develop --command mix emailjanitor.setup init \
  --directory "$PWD/.local/setup" \
  --owner owner@example.com \
  --public-url https://janitor.example.com
```

The directory must be new. It contains a 32-byte encryption key, a separate web
secret, metadata-only `settings.json`, and a local ignore file. Its permissions
are 0700 and its files are 0600. A second init refuses to replace existing keys.
`JANITOR_ENABLE_SELF_HOST` starts at `0`; no mailbox is enabled by this command.
The printed callback is the exact Google Web client redirect URI.

## Secrets and SOPS handoff

Encrypt `credential-key`, `web-secret`, and the downloaded Google client JSON
using your own SOPS age/KMS recipient policy. For example, after configuring that
policy, use SOPS binary mode for each file:

```sh
sops --encrypt --input-type binary --output-type binary \
  .local/setup/credential-key > secrets/credential-key.enc
```

Only encrypted files belong in the deployment repository. Keep decrypted files
out of OpenTofu variables, state, user-data, Nix expressions and the Nix store.
Do not use `builtins.readFile` on plaintext secrets. Arrange your chosen SOPS
integration to decrypt them at boot to `/run/secrets/emailjanitor/credential-key`,
`web-secret`, and `google-client.json`, with appropriate service ownership and
no world access. Keep the encryption key stable across upgrades and encrypted
backup restores. Losing it requires reconnecting Google accounts.

`settings.json` contains paths and public configuration, not secret values.
Before deploying, change its key/client paths to those runtime paths and add the
infrastructure output settings. The NixOS service's environment file uses the
same names as [SelfHost.Config](self-host-runtime.md); it is not JSON. Populate
that environment file through your deployment/SOPS integration. The CLI never
sources a shell file or evaluates settings as code.

## Google setup

Use an existing Google Cloud project with Gmail and Pub/Sub enabled. The
OpenTofu notification module creates the Pub/Sub and AWS federation resources;
it does not create the OAuth client or grant mailbox access.

Create a **Web application** OAuth client with redirect URI:

```text
https://janitor.example.com/auth/google/callback
```

Replace only the origin with the configured public URL. Download its JSON and
set `JANITOR_GOOGLE_CLIENT_JSON_FILE` to the protected runtime file. Google
requires the redirect URI to match the registered URI exactly. Configure the
consent audience for every Google account you intend to connect. An External
Testing app can have short-lived Gmail refresh grants; finish the appropriate
publishing/audience setup before treating this as a persistent installation.
See [Google's Web OAuth guide](https://developers.google.com/identity/protocols/oauth2/web-server).

Generate the **non-secret** workload credential configuration from the provider
resource and consumer service account returned by OpenTofu:

```sh
nix run .#setup -- wif-config \
  --provider projects/PROJECT_NUMBER/locations/global/workloadIdentityPools/POOL/providers/PROVIDER \
  --service-account CONSUMER@PROJECT_ID.iam.gserviceaccount.com \
  --output "$PWD/.local/aws-google.json"
```

This invokes the official `gcloud iam workload-identity-pools create-cred-config`
with `--aws --enable-imdsv2`, in a temporary isolated gcloud profile. It does not
implement signing or token exchange and refuses existing output files. The
configuration is not a service-account private key. Give it to the root-owned
Google token refresher; the application receives only its rotating token file
through `JANITOR_GOOGLE_TOKEN_FILE`. See the
[official gcloud command](https://docs.cloud.google.com/sdk/gcloud/reference/iam/workload-identity-pools/create-cred-config).

## SES and DNS steps

Choose a dedicated mail domain or delegated subdomain. Review the new Route53
zone's nameservers and delegate it from its parent. Leave existing unrelated
mail routing in place. Wait for SES domain/DKIM verification in `us-east-1`, and
set `JANITOR_MAIL_SENDER`, `JANITOR_MAIL_BUCKET`, `JANITOR_MAIL_QUEUE_URL`, and
`JANITOR_MAIL_TOPIC_ARN` from your deployment.

Receiving also needs an intentionally activated SES receipt rule set. Inspect
the region's existing rules before changing it; the reference defaults to
`activate_receiving = false`. See [SES receiving setup](https://docs.aws.amazon.com/ses/latest/dg/receiving-email-setting-up.html).
In the SES sandbox, verify your destination inboxes before testing sends. Apply
for production sending access when needed; this approval is outside OpenTofu.
See [SES production access](https://docs.aws.amazon.com/ses/latest/dg/request-production-access.html).

## Local checks and first connection

```sh
nix run .#setup -- doctor --settings /path/to/settings.json
```

Without `--settings`, doctor reads the current process environment. It shares
the runtime configuration validators, validates the local rotating token file
and transport resource shapes, and issues only `SELECT 1` to the configured
Unix-socket PostgreSQL database. Output contains fixed statuses, not credentials.
It does not prove DNS/TLS, cloud IAM, model access, SES sending/receiving, Google
consent or Gmail notification delivery; `processing_ready` remains false.
An incomplete check exits nonzero rather than claiming setup succeeded.

After the infrastructure and runtime are deployed, complete the existing
infrastructure readiness checks using a dedicated test inbox. Then explicitly
enable the service, open the configured public URL, sign in as the fixed owner,
and connect inboxes in the browser. New arrivals begin at the successful
connection baseline. There is no automatic pre-existing inbox cleanup.
