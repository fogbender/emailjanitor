{
  description = "Email Janitor development and verification tools";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/8eeec934ae0dbeca3d7868c059568a65c08b2fc3";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in {
      packages = forAllSystems (system:
        let pkgs = import nixpkgs { inherit system; };
        in {
          google-auth-bridge = pkgs.buildNpmPackage {
            pname = "emailjanitor-google-token";
            version = "0.1.0";
            src = ./bridge/google-auth;
            nodejs = pkgs.nodejs_22;
            npmDepsHash = "sha256-EYI2Fz+mWTgzO2kxk6pDo5mUvfyiNBN+gG0/IIjfm/4=";
            npmFlags = [ "--ignore-scripts" ];
            dontNpmBuild = true;
            nativeBuildInputs = [ pkgs.makeWrapper ];
            doCheck = true;
            checkPhase = "npm test";
            postInstall = ''
              rm "$out/bin/emailjanitor-google-token"
              makeWrapper ${pkgs.nodejs_22}/bin/node "$out/bin/emailjanitor-google-token" \
                --add-flags "$out/lib/node_modules/@emailjanitor/google-token-bridge/cli.mjs" \
                --unset NODE_OPTIONS --unset NODE_DEBUG --unset DEBUG \
                --unset NODE_EXTRA_CA_CERTS --unset GOOGLE_SDK_NODE_LOGGING
            '';
            doInstallCheck = true;
            installCheckPhase = ''
              runHook preInstallCheck
              set +e
              NODE_OPTIONS='--require=/nonexistent-emailjanitor-module' \
                NODE_DEBUG=http GOOGLE_SDK_NODE_LOGGING='*' \
                "$out/bin/emailjanitor-google-token" >bridge.stdout 2>bridge.stderr
              janitor_bridge_status=$?
              set -e
              test "$janitor_bridge_status" -eq 1
              test ! -s bridge.stdout
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
