# Locked release packaging

`nix build .#emailjanitor` builds a production Mix release from the pinned
nixpkgs toolchain and `mix.lock`. `nix flake check` boots that installed artifact
inside the Nix sandbox and checks the packaged prompt and transport module. It
requires no mailbox credentials and makes no provider calls. The dependency
fixed-output hash must be regenerated and reviewed when `mix.lock` changes.
Only `mix.exs`, `mix.lock`, `config`, `lib` and `priv` enter the application
source closure; local OAuth/SOPS files, test data and build artifacts are excluded.
Do not put plaintext credentials inside those source directories.

The package always disables distributed Erlang and generates a fresh random
cookie for each command. No shared cookie is stored in the Nix closure. Distributed
`rpc`/remote shells are unsupported; use a separate `eval` process for maintenance.
The unit keeps generated runtime configuration in private `/run/emailjanitor`,
outside backups, and preserves `ProcSubset=all` with `ProtectProc=invisible` so
owner recovery can read boot identity and its own UID's process-start records.

The flake exports `nixosModules.default`, which defaults to this exact pinned
release even if the NixOS host uses another nixpkgs. Import that flake module into
the image. The lower-level path module `nix/module.nix` still requires an explicit
`services.emailjanitor.package`; supply the flake package when using it. An
operator can supply another reviewed package. Direct source imports also filter
Git working trees to tracked files, excluding ignored/untracked files. The release contains
the reviewed engine and SDK transport; merely starting it does not configure an
inbox or establish that supervised host workers are ready. Single-user host
startup, Google connection/chat, exact scoped migrations, runtime secrets and
live sending/receiving remain application and launch integration gates. This
packaging change provisions no infrastructure and sends no mail.
