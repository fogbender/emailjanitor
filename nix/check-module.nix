let
  lock = builtins.fromJSON (builtins.readFile ../flake.lock);
  locked = lock.nodes.nixpkgs.locked;
  nixpkgs = builtins.fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/${locked.rev}.tar.gz";
    sha256 = locked.narHash;
  };
  pkgs = import nixpkgs { system = "x86_64-linux"; };
  host = import (nixpkgs + "/nixos/lib/eval-config.nix") {
    system = "x86_64-linux";
    modules = [
      ./module.nix
      ({ ... }: {
        system.stateVersion = "26.05";
        fileSystems."/" = { device = "/dev/disk/by-label/nixos"; fsType = "ext4"; };
        boot.loader.grub.devices = [ "/dev/vda" ];
        services.emailjanitor.enable = true;
        # This is only an evaluation fixture, not a deployable application release.
        services.emailjanitor.package = pkgs.writeShellScriptBin "email_janitor" "exit 0";
      })
    ];
  };
  service = host.config.systemd.services.emailjanitor;
in assert service.serviceConfig.EnvironmentFile == "/run/secrets/emailjanitor/environment";
   assert service.serviceConfig.User == "emailjanitor";
   assert service.environment.ERL_CRASH_DUMP == "/dev/null";
   assert service.serviceConfig.LimitCORE == 0;
   assert service.serviceConfig.ProcSubset == "all";
   assert service.serviceConfig.ProtectProc == "invisible";
   assert service.environment.RELEASE_TMP == "/run/emailjanitor/release";
   assert service.serviceConfig.RuntimeDirectoryMode == "0700";
   assert host.config.services.postgresql.enableTCPIP == false;
   assert host.config.services.postgresql.settings.listen_addresses == "";
   assert builtins.elem "multi-user.target" service.wantedBy;
   assert builtins.elem "postgresql.target" service.after;
   assert builtins.elem "postgresql.target" service.requires;
   assert builtins.all (a: a.assertion) host.config.assertions;
   builtins.deepSeq {
     app = host.config.systemd.units."emailjanitor.service".text;
     postgres = host.config.systemd.units."postgresql.service".text;
   } { valid = true; unit = service.serviceConfig.ExecStart; }
