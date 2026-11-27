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
        services.emailjanitor.replyParserPackage =
          lib.mkDefault self.packages.${pkgs.stdenv.hostPlatform.system}.reply-parser;
        services.emailjanitor.googleHelperPackage =
          lib.mkDefault self.packages.${pkgs.stdenv.hostPlatform.system}.google-auth-bridge;
        services.emailjanitor-google-token.package =
          lib.mkDefault self.packages.${pkgs.stdenv.hostPlatform.system}.google-auth-bridge;
      };
      nixosModules.google-token = { lib, pkgs, ... }: {
        imports = [ ./nix/google-token-module.nix ];
        services.emailjanitor-google-token.package =
          lib.mkDefault self.packages.${pkgs.stdenv.hostPlatform.system}.google-auth-bridge;
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
          setup = pkgs.writeShellApplication {
            name = "emailjanitor-setup";
            runtimeInputs = [ pkgs.jq pkgs.google-cloud-sdk ];
            text = ''
              JANITOR_ENABLE_SELF_HOST=0
              export JANITOR_ENABLE_SELF_HOST
              EMAILJANITOR_SETUP_ARGS=$(jq -cn --args '$ARGS.positional' -- "$@")
              export EMAILJANITOR_SETUP_ARGS
              exec ${emailjanitor}/bin/email_janitor eval \
                'System.halt(EmailJanitor.Setup.CLI.main_json(System.fetch_env!("EMAILJANITOR_SETUP_ARGS")))'
            '';
          };
          reply-parser = pkgs.buildNpmPackage {
            pname = "emailjanitor-reply-parser";
            version = "0.1.0";
            src = ./bridge/reply-parser;
            nodejs = pkgs.nodejs_22;
            npmDepsHash = "sha256-mhHUA91Z6UddfoicT5omZRB7CG5S3kCJfnIASuFnC1M=";
            npmFlags = [ "--ignore-scripts" ];
            dontNpmBuild = true;
            nativeBuildInputs = [ pkgs.makeBinaryWrapper ];
            doCheck = true;
            checkPhase = "npm test";
            postInstall = ''
              rm "$out/bin/emailjanitor-reply-parser"
              makeBinaryWrapper ${pkgs.coreutils}/bin/env "$out/bin/emailjanitor-reply-parser" \
                --add-flags "-i ${pkgs.coreutils}/bin/timeout --signal=KILL 3s ${pkgs.nodejs_22}/bin/node --max-old-space-size=64 $out/lib/node_modules/@emailjanitor/reply-parser/cli.mjs"
            '';
            doInstallCheck = true;
            installCheckPhase = ''
              runHook preInstallCheck
              printf 'exit 90\n' >parser.bash-env
              printf '%s\n' '{"body":"Mark Bob Done","subject":"Janitor","reply_expected":false}' | \
                NODE_OPTIONS='--require=/nonexistent-emailjanitor-module' \
                BASH_ENV="$PWD/parser.bash-env" NODE_DEBUG='*' \
                "$out/bin/emailjanitor-reply-parser" >parser.stdout 2>parser.stderr
              test ! -s parser.stderr
              grep -q '"authored":"Mark Bob Done"' parser.stdout
              runHook postInstallCheck
            '';
            meta = {
              description = "Bounded stdin/stdout-only maintained email reply and forward parser";
              license = pkgs.lib.licenses.mit;
              mainProgram = "emailjanitor-reply-parser";
            };
          };
          google-auth-bridge = pkgs.buildNpmPackage {
            pname = "emailjanitor-google-token";
            version = "0.1.0";
            src = ./bridge/google-auth;
            nodejs = pkgs.nodejs_22;
            npmDepsHash = "sha256-guVbJYRmU1jMjKI2sehAzxmtue/yA+Dwl5CjaYkwee0=";
            npmFlags = [ "--ignore-scripts" ];
            dontNpmBuild = true;
            nativeBuildInputs = [ pkgs.makeBinaryWrapper pkgs.python3 ];
            doCheck = true;
            checkPhase = "npm test";
            postInstall = ''
              rm "$out/bin/emailjanitor-google-token"
              rm "$out/bin/emailjanitor-google-revoke"
              makeBinaryWrapper ${pkgs.coreutils}/bin/env "$out/bin/emailjanitor-google-token" \
                --add-flags "-i ${pkgs.nodejs_22}/bin/node $out/lib/node_modules/@emailjanitor/google-token-bridge/cli.mjs"
              makeBinaryWrapper ${pkgs.coreutils}/bin/env "$out/bin/emailjanitor-google-revoke" \
                --add-flags "-i ${pkgs.coreutils}/bin/timeout --signal=KILL 13s ${pkgs.nodejs_22}/bin/node --max-old-space-size=64 $out/lib/node_modules/@emailjanitor/google-token-bridge/revoke-cli.mjs"
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
              set +e
              printf '{}\n' | NODE_OPTIONS='--require=/nonexistent-emailjanitor-module' \
                BASH_ENV="$PWD/bridge.bash-env" NODE_DEBUG='*' \
                "$out/bin/emailjanitor-google-revoke" >revoke.stdout 2>revoke.stderr
              janitor_revoke_status=$?
              set -e
              test "$janitor_revoke_status" -eq 1
              test ! -s revoke.stdout
              printf 'Google grant revocation unavailable.\n' >revoke.expected
              cmp revoke.expected revoke.stderr
              # The actual installed helper must end even if its BEAM owner
              # disappears before supplying a frame. No Google request is made.
              python3 - "$out/bin/emailjanitor-google-revoke" <<'PY'
              import subprocess, sys
              p = subprocess.Popen([sys.argv[1]], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
              try:
                  assert p.wait(timeout=15) == 1
                  assert p.stdout.read() == b""
                  assert p.stderr.read() == b'Google grant revocation unavailable.\n'
              finally:
                  if p.poll() is None:
                      p.kill()
                      p.wait()
                  p.stdin.close()
              PY
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
          setup = pkgs.runCommand "emailjanitor-setup-check" {
            nativeBuildInputs = [ self.packages.${system}.setup pkgs.jq ];
          } ''
            export HOME="$TMPDIR"
            export ERL_CRASH_DUMP=/dev/null
            export RELEASE_TMP="$TMPDIR/release"
            JANITOR_ENABLE_SELF_HOST=1 emailjanitor-setup --help > help.txt
            grep -q 'workers remain disabled' help.txt
            emailjanitor-setup init --directory "$TMPDIR/private" \
              --owner owner@example.com --public-url https://janitor.example.com > init.json
            test "$(stat -c %a "$TMPDIR/private")" = 700
            test "$(stat -c %s "$TMPDIR/private/credential-key")" = 32
            jq -e '.JANITOR_ENABLE_SELF_HOST == "0"' "$TMPDIR/private/settings.json"
            if emailjanitor-setup doctor --settings "$TMPDIR/private/settings.json" > doctor.json; then
              exit 1
            else
              janitor_setup_doctor_status=$?
            fi
            test "$janitor_setup_doctor_status" -eq 2
            jq -e '.checks.database == "unavailable" and .local_ready == false and .processing_ready == false' doctor.json
            emailjanitor-setup wif-config \
              --provider projects/123456789012/locations/global/workloadIdentityPools/janitor-pool/providers/aws-provider \
              --service-account janitor-service@emailjanitor-fixture.iam.gserviceaccount.com \
              --output "$TMPDIR/aws-google.json" > wif.json
            jq -e '.credential_source.environment_id == "aws1" and .credential_source.imdsv2_session_token_url == "http://169.254.169.254/latest/api/token"' "$TMPDIR/aws-google.json"
            if emailjanitor-setup init --directory "$TMPDIR/private" \
              --owner owner@example.com --public-url https://janitor.example.com; then
              exit 1
            fi
            touch "$out"
          '';
          release = pkgs.runCommand "emailjanitor-release-check" {
            nativeBuildInputs = [ self.packages.${system}.emailjanitor self.packages.${system}.reply-parser self.packages.${system}.google-auth-bridge pkgs.python3 pkgs.postgresql_17 pkgs.curl ];
          } ''
            export HOME="$TMPDIR"
            export ERL_CRASH_DUMP=/dev/null
            export RELEASE_TMP="$TMPDIR/release"
            test ! -e ${self.packages.${system}.emailjanitor.src}/vendor
            email_janitor eval '
              {:ok, _} = Application.ensure_all_started(:email_janitor)
              true = is_pid(Process.whereis(EmailJanitor.Supervisor))
              true = File.regular?(Application.app_dir(:email_janitor, "priv/prompts/classify.txt"))
              true = Code.ensure_loaded?(EmailJanitor.Mail.SDK)
              true = Code.ensure_loaded?(:mimemail)
              true = Code.ensure_loaded?(EmailJanitor.SelfHost.Web)
              true = Code.ensure_loaded?(EmailJanitor.SelfHostWeb.Endpoint)
              true = Code.ensure_loaded?(Oban)
              false = Code.ensure_loaded?(Oban.Pro.Engine)
              "2.24.1" = to_string(Application.spec(:oban, :vsn))
              true = File.regular?(Application.app_dir(:email_janitor, "priv/static/selfhost.js"))
            '
            python3 ${./scripts/check-release-cookie.py} \
              ${self.packages.${system}.emailjanitor} email_janitor ${pkgs.coreutils}/bin/base64
            ${pkgs.lib.optionalString pkgs.stdenv.isLinux "bash ${./scripts/check-release-selfhost}"}
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
              (self.packages.${system}.reply-parser)
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
        } // pkgs.lib.optionalAttrs pkgs.stdenv.isLinux {
          browser = pkgs.mkShell {
            inputsFrom = [ self.devShells.${system}.default ];
            packages = with pkgs; [ chromium openssl curl python3 ];
            JANITOR_BROWSER_EXECUTABLE = "${pkgs.chromium}/bin/chromium";
          };
        });
    };
}
