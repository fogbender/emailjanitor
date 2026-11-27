let
  lock = builtins.fromJSON (builtins.readFile ../flake.lock);
  locked = lock.nodes.nixpkgs.locked;
  nixpkgs = builtins.fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/${locked.rev}.tar.gz";
    sha256 = locked.narHash;
  };
  pkgs = import nixpkgs { system = "x86_64-linux"; };
  outputs = (import ../flake.nix).outputs {
    self = outputs;
    nixpkgs = { outPath = nixpkgs; lib = pkgs.lib; };
  };
  host = import (nixpkgs + "/nixos/lib/eval-config.nix") {
    system = "x86_64-linux";
    modules = [
      outputs.nixosModules.default
      ({ ... }: {
        system.stateVersion = "26.05";
        fileSystems."/" = { device = "/dev/disk/by-label/nixos"; fsType = "ext4"; };
        boot.loader.grub.devices = [ "/dev/vda" ];
        services.emailjanitor.enable = true;
      })
    ];
  };
  service = host.config.systemd.services.emailjanitor;
  differentHost = host.extendModules {
    modules = [{ nixpkgs.overlays = [(final: prev: {
      coreutils = prev.coreutils.overrideAttrs { pname = "different-host-coreutils"; };
    })]; }];
  };
  tokenHost = host.extendModules {
    modules = [{ services.emailjanitor-google-token = {
      enable = true;
      configuration = {
        type = "external_account";
        audience = "//iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/janitor-pool/providers/janitor-aws";
        subject_token_type = "urn:ietf:params:aws:token-type:aws4_request";
        token_url = "https://sts.googleapis.com/v1/token";
        service_account_impersonation_url = "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/janitor-pubsub@janitor-project.iam.gserviceaccount.com:generateAccessToken";
        credential_source = {
          environment_id = "aws1";
          region_url = "http://169.254.169.254/latest/meta-data/placement/availability-zone";
          url = "http://169.254.169.254/latest/meta-data/iam/security-credentials";
          regional_cred_verification_url = "https://sts.{region}.amazonaws.com?Action=GetCallerIdentity&Version=2011-06-15";
          imdsv2_session_token_url = "http://169.254.169.254/latest/api/token";
        };
      };
    }; }];
  };
  tokenService = tokenHost.config.systemd.services.emailjanitor-google-token;
  webHost = host.extendModules {
    modules = [{ services.emailjanitor.publicHostname = "janitor.example.com"; }];
  };
  proxy = webHost.config.services.nginx.virtualHosts."janitor.example.com";
in assert service.serviceConfig.EnvironmentFile == "/run/secrets/emailjanitor/environment";
   assert host.config.services.emailjanitor.package.drvPath == outputs.packages.x86_64-linux.emailjanitor.drvPath;
   assert differentHost.pkgs.coreutils.drvPath != pkgs.coreutils.drvPath;
   assert differentHost.config.services.emailjanitor.package.drvPath == outputs.packages.x86_64-linux.emailjanitor.drvPath;
   assert service.serviceConfig.User == "emailjanitor";
   assert service.environment.ERL_CRASH_DUMP == "/dev/null";
   assert service.serviceConfig.LimitCORE == 0;
   assert service.serviceConfig.ProcSubset == "all";
   assert service.serviceConfig.ProtectProc == "invisible";
   assert service.environment.RELEASE_TMP == "/run/emailjanitor/release";
   assert service.environment.JANITOR_ENABLE_SELF_HOST == "1";
   assert service.environment.JANITOR_CREDENTIAL_KEY_FILE == "%d/credential-key";
   assert service.environment.JANITOR_SECRET_KEY_BASE_FILE == "%d/web-secret";
   assert service.environment.JANITOR_GOOGLE_CLIENT_JSON_FILE == "%d/google-client.json";
   assert builtins.length service.serviceConfig.LoadCredential == 3;
   assert pkgs.lib.hasInfix "SelfHost.Release.migrate()" service.serviceConfig.ExecStartPre;
   assert tokenHost.config.systemd.services.emailjanitor.environment.JANITOR_GOOGLE_TOKEN_FILE == "/run/emailjanitor-google-token/token.json";
   assert tokenService.serviceConfig.User == "root";
   assert tokenService.serviceConfig.Group == "emailjanitor";
   assert tokenService.serviceConfig.RuntimeDirectoryMode == "0750";
   assert tokenService.serviceConfig.RuntimeDirectoryPreserve == "yes";
   assert builtins.elem "-/run/credentials" tokenService.serviceConfig.InaccessiblePaths;
   assert tokenHost.config.systemd.timers.emailjanitor-google-token.timerConfig.OnUnitActiveSec == "60s";
   assert proxy.forceSSL && proxy.enableACME;
   assert pkgs.lib.hasInfix "proxy_set_header X-Real-IP $remote_addr;" proxy.locations."/".extraConfig;
   assert !(pkgs.lib.hasInfix "$http_x_real_ip" proxy.locations."/".extraConfig);
   assert builtins.elem 443 webHost.config.networking.firewall.allowedTCPPorts;
   assert builtins.all (a: a.assertion) webHost.config.assertions;
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
     token = tokenHost.config.systemd.units."emailjanitor-google-token.service".text;
     tokenTimer = tokenHost.config.systemd.units."emailjanitor-google-token.timer".text;
     nginx = webHost.config.systemd.units."nginx.service".text;
   } { valid = true; unit = service.serviceConfig.ExecStart; }
