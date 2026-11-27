{ config, lib, pkgs, ... }:
let
  cfg = config.services.emailjanitor;
in {
  options.services.emailjanitor = {
    enable = lib.mkEnableOption "the single-user Email Janitor service";
    package = lib.mkOption {
      type = lib.types.package;
      description = "Built Elixir release providing bin/email_janitor. No release is built by this module.";
    };
    environmentFile = lib.mkOption {
      type = lib.types.str;
      default = "/run/secrets/emailjanitor/environment";
      description = "Absolute runtime SOPS-decrypted environment file; never a Nix path or plaintext store value.";
    };
    bedrockModelId = lib.mkOption {
      type = lib.types.str;
      default = "amazon.nova-micro-v1:0";
      description = "The same regional Bedrock model granted by the OpenTofu reference deployment.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [{
      assertion = lib.hasPrefix "/run/" cfg.environmentFile;
      message = "Email Janitor secrets must be supplied at a runtime /run path, not put into the Nix store.";
    }];
    users.groups.emailjanitor = {};
    users.users.emailjanitor = { isSystemUser = true; group = "emailjanitor"; };
    services.postgresql = {
      enable = true;
      package = lib.mkDefault pkgs.postgresql_17;
      enableTCPIP = lib.mkDefault false;
      ensureDatabases = [ "emailjanitor" ];
      ensureUsers = [{ name = "emailjanitor"; ensureDBOwnership = true; }];
    };
    systemd.services.emailjanitor = {
      description = "Single-user Email Janitor";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" "postgresql.target" ];
      wants = [ "network-online.target" ];
      requires = [ "postgresql.target" ];
      environment = {
        JANITOR_DATABASE_SOCKET = "/run/postgresql";
        JANITOR_DATABASE_NAME = "emailjanitor";
        JANITOR_DATABASE_USER = "emailjanitor";
        ERL_CRASH_DUMP = "/dev/null";
        RELEASE_DISTRIBUTION = "none";
        AWS_REGION = "us-east-1";
        JANITOR_MODEL_PROVIDER = "bedrock";
        JANITOR_MODEL_ID = cfg.bedrockModelId;
      };
      serviceConfig = {
        Type = "simple";
        User = "emailjanitor";
        Group = "emailjanitor";
        ExecStart = "${cfg.package}/bin/email_janitor start";
        EnvironmentFile = cfg.environmentFile;
        WorkingDirectory = "/var/lib/emailjanitor";
        StateDirectory = "emailjanitor";
        StateDirectoryMode = "0700";
        UMask = "0077";
        Restart = "on-failure";
        RestartSec = 5;
        LimitCORE = 0;
        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        LockPersonality = true;
        ProtectClock = true;
        ProtectKernelLogs = true;
        ProtectHostname = true;
        RestrictRealtime = true;
        SystemCallArchitectures = "native";
        ProtectProc = "invisible";
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
        RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
      };
      # A missed restart must not leave Janitor permanently failed after a short outage.
      unitConfig.StartLimitIntervalSec = 0;
    };
  };
}
