# Single-user browser interface

The optional browser interface provides Google sign-in, linked Google accounts
and chat with Janitor. It uses the same single-user host and shared engine as
the background service. The MIT library does not start a web server by default.

The self-hosted runtime starts `EmailJanitor.SelfHost.Web` only when explicitly
enabled and all required engine capabilities and host configuration are present.
The web server listens on loopback (port4000, or `JANITOR_WEB_PORT`). Put it
behind the host's HTTPS proxy using its configured public URL. It requires a
Google Web application OAuth client with the exact callback URL
`https://<your-host>/auth/google/callback`. Host configuration supplies the
owner identity, OAuth credentials, encryption key and stable web secret.

The proxy must overwrite `X-Real-IP` with the actual client address, for example
Nginx `proxy_set_header X-Real-IP $remote_addr;`. Janitor accepts that header only
from a loopback peer; other peers use their socket address. It hashes canonical
IP buckets (IPv6 /64) for anonymous OAuth attempt limits, storing no raw address.
Each client can have three live attempts within the ten-minute expiry; a separate
1,000-row backstop bounds all anonymous state. Signed-in owner connection flows
have their own authenticated access. A visitor reaching their limit does not
consume another client's allowance. Proxy configuration is part of readiness.

Only the configured owner can sign in. The owner can connect multiple Google
accounts, choose the inbox for a conversation and disconnect an account.
Browser timezone is supplied during connection for each account's 9pm digest.
Billing and tenant management belong to the separate SaaS application.

Browser sessions use an encrypted, secure, HttpOnly `__Host-` cookie containing
an opaque token; the database stores its hash and expiry. Logout revokes it.
OAuth attempts are encrypted, single-use and tied to the initiating browser
and current session. Private forms require CSRF tokens. Chat runs in bounded
server-owned processes; HTTP disconnects do not release an active request slot.

Requests and assistant text remain transient. A failed chat renders an explicit
retry with the original request UUID in that no-store response, while the blank
composer receives a fresh UUID. Email bodies, requests and model replies are
not written to browser session storage, jobs, database receipts or application
request logs.

## Verification

Run the normal checks with `nix develop --command bash scripts/check`.
The authenticated browser and session tests use real private PostgreSQL.

On Linux, run `nix develop .#browser --command bash scripts/check-browser` for
real Chromium HTTPS desktop/mobile checks. It creates a disposable loopback
server, private database and synthetic OAuth/host adapters. External network
requests are blocked in the browser. It checks sign-in, account connection,
timezone, cookies, chat, retry IDs, CSRF, inbox isolation, disconnect and session
revocation. It also checks the database dump and server logs for a private body
sentinel. Screenshots are written to an owned private directory under `/tmp`.
No real Google account, mailbox, model, email or billing service is contacted.
