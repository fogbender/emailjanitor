# Instance migration registry

All shared-library migrations use the host's explicit `ej_*` schema prefix and
share that prefix's `schema_migrations` table. Allocate versions here before
adding a migration, including optional modules. Do not start a separate sequence
inside an optional module.

| Version | Owner | Installation |
| --- | --- | --- |
| 1 | Core inboxes/actions | `Store.install/1` |
| 2 | Core action candidates | `Store.install/1` |
| 3 | Conversational preferences/receipts | `Preferences.install/1` |
| 4 | Mail outbox/temporary spool metadata | `Mail.Store.install/1` |
| 5 | Daily digest metadata | `Digest.install/1` |
| 6 | Target categories, remaining candidate/cancelled metadata and review fences | `Store.install/1` |
| 7 | Exact restoration effects and durable per-message protections | `Store.install/1` / `Restore.install/1` |
| 8 | Body-free conversational effect/context receipts | `Conversation.Ledger.install/1` |
| 9 | Conversation execution ownership and exact action bindings | `Conversation.Ledger.install/1` |
| 10 | Gmail ingestion checkpoints/arrival IDs | Ingestion installer |
| 11 | Inbox-worker recovery/settlement/deferred provenance ledger | `Worker.install/1` |
| 12 | Staged digest action headers | `Digest.install_staging/1` |
| 13 | Body-free incoming feedback/reply receipts | Feedback installer (in development) |

Changes to an already released schema require a new
version; never alter an existing released migration. The private SaaS application's
global `public` schema has its own independent registry and migration table.
