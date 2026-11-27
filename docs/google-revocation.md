# Google grant retirement

`Google.OAuth.revoke(config, credential_content, executable: absolute_pinned_helper)`
delegates to the pinned official `google-auth-library` `OAuth2Client.revokeToken`
method. `.#google-auth-bridge` installs `emailjanitor-google-revoke` alongside the
federation helper. The runtime never receives a token on its argument list, writes
it to a temporary file, or falls back to a personal Google profile. A separate
scrubbed process receives only the stored refresh token on bounded stdin. It uses
Google's fixed endpoint, no redirects/retries, a 10-second HTTP deadline, a
12-second process deadline and a 4 KiB response limit. The Elixir caller has a
15-second outer deadline; the Nix wrapper has an independent OS watchdog.

Only HTTP 200 returns `:ok`. Exact Google `400 invalid_token` becomes
`{:error, :refresh_token_invalid}`, never successful erasure. All other failures
return `{:error, :revocation_unavailable}` without provider text. An access-only
credential is insufficient: an expired access token does not establish that the
offline grant was removed. A crash after remote success but before a local commit
may require retry or visible manual provider cleanup if Google returns an invalid
token on replay. Grant retirement may take time to propagate at Google.

Hosts first fence ordinary work, durably retain the encrypted pending credential,
then call this boundary outside database locks. They erase the pending credential
and release the identity only after positive confirmation. Timeouts and invalid
tokens remain honestly pending; the SDK boundary does not manage the host's
durable queue. New Google grants for the same immutable subject and project must
remain blocked throughout revocation, including during the remote call, so an old
revoke cannot invalidate a newly accepted connection.

Use an isolated product Google Cloud project. Google documents that revoking
access removes **all scopes and all OAuth clients registered under that project**
for the user. Reusing a project that also owns a personal desktop Janitor or an
Inbox Zero client can revoke those connections too. Existing personal credentials
are not a safe live test fixture. See Google's
[revocation documentation](https://developers.google.com/identity/protocols/oauth2/web-server#tokenrevoke)
and the maintained [OAuth2Client API](https://googleapis.dev/nodejs/google-auth-library/latest/classes/OAuth2Client.html).

Tests use SDK HTTP fixtures and an isolated stdin/stdout process. They do not
revoke any real Google grant or enable a mailbox.
