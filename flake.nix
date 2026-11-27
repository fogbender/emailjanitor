{
  description = "Email Janitor development and verification tools";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/8eeec934ae0dbeca3d7868c059568a65c08b2fc3";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in {
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
