{
  description = "Email Janitor development and verification tools";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/8eeec934ae0dbeca3d7868c059568a65c08b2fc3";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in {
      nixosModules.default = { lib, pkgs, ... }: {
        imports = [ ./nix/module.nix ];
        services.emailjanitor.package =
          lib.mkDefault self.packages.${pkgs.stdenv.hostPlatform.system}.emailjanitor;
      };
      packages = forAllSystems (system:
        let pkgs = import nixpkgs { inherit system; };
        in rec {
          default = emailjanitor;
          emailjanitor = import ./nix/release.nix {
            inherit (pkgs) lib coreutils;
            beam = pkgs.beam.packages.erlang_28;
            src = ./.;
          };
          google-auth-bridge = pkgs.buildNpmPackage {
            pname = "emailjanitor-google-token";
            version = "0.1.0";
            src = ./bridge/google-auth;
            nodejs = pkgs.nodejs_22;
            npmDepsHash = "sha256-EYI2Fz+mWTgzO2kxk6pDo5mUvfyiNBN+gG0/IIjfm/4=";
            npmFlags = [ "--ignore-scripts" ];
            dontNpmBuild = true;
            nativeBuildInputs = [ pkgs.makeBinaryWrapper ];
            doCheck = true;
            checkPhase = "npm test";
            postInstall = ''
              rm "$out/bin/emailjanitor-google-token"
              makeBinaryWrapper ${pkgs.coreutils}/bin/env "$out/bin/emailjanitor-google-token" \
                --add-flags "-i ${pkgs.nodejs_22}/bin/node $out/lib/node_modules/@emailjanitor/google-token-bridge/cli.mjs"
            '';
            doInstallCheck = true;
            installCheckPhase = ''
              runHook preInstallCheck
              printf 'echo BASH_ENV_RAN >&2; exit 0\n' >bridge.bash-env
              set +e
              NODE_OPTIONS='--require=/nonexistent-emailjanitor-module' \
                BASH_ENV="$PWD/bridge.bash-env" \
                NODE_DEBUG=http GOOGLE_SDK_NODE_LOGGING='*' \
                NODE_USE_ENV_PROXY=1 NODE_TLS_REJECT_UNAUTHORIZED=0 \
                HTTP_PROXY=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 \
                ALL_PROXY=http://127.0.0.1:9 NO_PROXY="" \
                NODE_PATH=/nonexistent-emailjanitor-modules \
                OPENSSL_CONF=/nonexistent-emailjanitor-openssl \
                SSL_CERT_FILE=/nonexistent-emailjanitor-ca SSL_CERT_DIR=/nonexistent-emailjanitor-certs \
                NODE_REDIRECT_WARNINGS=bridge.warnings \
                "$out/bin/emailjanitor-google-token" >bridge.stdout 2>bridge.stderr
              janitor_bridge_status=$?
              set -e
              test "$janitor_bridge_status" -eq 1
              test ! -s bridge.stdout
              test ! -e bridge.warnings
              printf 'Google service token refresh failed.\n' >bridge.expected
              cmp bridge.expected bridge.stderr
              runHook postInstallCheck
            '';
            meta = {
              description = "Root-owned SDK helper for short-lived Google federation tokens";
              license = pkgs.lib.licenses.mit;
              mainProgram = "emailjanitor-google-token";
            };
          };
        });
      checks = forAllSystems (system:
        let pkgs = import nixpkgs { inherit system; };
        in {
          release = pkgs.runCommand "emailjanitor-release-check" {
            nativeBuildInputs = [ self.packages.${system}.emailjanitor pkgs.python3 ];
          } ''
            export HOME="$TMPDIR"
            export ERL_CRASH_DUMP=/dev/null
            export RELEASE_TMP="$TMPDIR/release"
            email_janitor eval '
              {:ok, _} = Application.ensure_all_started(:email_janitor)
              true = is_pid(Process.whereis(EmailJanitor.Supervisor))
              true = File.regular?(Application.app_dir(:email_janitor, "priv/prompts/classify.txt"))
              true = Code.ensure_loaded?(EmailJanitor.Mail.SDK)
            '
            python3 ${./scripts/check-release-cookie.py} \
              ${self.packages.${system}.emailjanitor} email_janitor ${pkgs.coreutils}/bin/base64
            touch "$out"
          '';
        });
      devShells = forAllSystems (system:
        let pkgs = import nixpkgs { inherit system; };
        in {
          default = pkgs.mkShell {
            packages = with pkgs; [
              beam.packages.erlang_28.elixir
              beam.packages.erlang_28.hex
              beam.packages.erlang_28.rebar3
              postgresql_17
              git
              jq
              nodejs_22
              opentofu
              sops
            ];
            shellHook = ''
              janitor_root="$PWD"
              while [ ! -f "$janitor_root/flake.nix" ]; do
                if [ "$janitor_root" = / ]; then
                  echo "Enter the Email Janitor source directory before nix develop." >&2
                  exit 1
                fi
                janitor_root=$(dirname "$janitor_root")
              done
              export MIX_HOME="$janitor_root/.local/mix"
              export HEX_HOME="$janitor_root/.local/hex"
              export MIX_REBAR3="${pkgs.beam.packages.erlang_28.rebar3}/bin/rebar3"
              export MIX_PATH="${pkgs.beam.packages.erlang_28.hex}/lib/erlang/lib/hex/ebin"
              export LANG=C.UTF-8
            '';
          };
        });
    };
}
