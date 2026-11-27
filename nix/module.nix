{ config, lib, pkgs, ... }:
let
  cfg = config.services.emailjanitor;
in {
  imports = [ ./google-token-module.nix ];
  options.services.emailjanitor = {
    enable = lib.mkEnableOption "the single-user Email Janitor service";
    package = lib.mkOption {
      type = lib.types.package;
      description = "Elixir release providing bin/email_janitor. The flake's NixOS module defaults to its pinned package.";
    };
    replyParserPackage = lib.mkOption {
      type = lib.types.package;
      description = "Pinned maintained reply parser providing bin/emailjanitor-reply-parser; the flake supplies its matching package.";
    };
    environmentFile = lib.mkOption {
      type = lib.types.str;
      default = "/run/secrets/emailjanitor/environment";
      description = "Absolute runtime SOPS-decrypted environment file; never a Nix path or plaintext store value.";
    };
    credentialKeyFile = lib.mkOption {
      type = lib.types.str;
      default = "/run/secrets/emailjanitor/credential-key";
      description = "Stable 32 raw-byte credential encryption key, decrypted by SOPS at runtime.";
    };
    webSecretFile = lib.mkOption {
      type = lib.types.str;
      default = "/run/secrets/emailjanitor/web-secret";
      description = "Stable runtime Phoenix signing secret of at least 64 bytes.";
    };
    googleClientFile = lib.mkOption {
      type = lib.types.str;
      default = "/run/secrets/emailjanitor/google-client.json";
      description = "Runtime Google Web OAuth client JSON with the exact public /auth/google/callback redirect.";
    };
    publicHostname = lib.mkOption {
      type = lib.types.nullOr (lib.types.addCheck
        (lib.types.strMatching "[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?([.][a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+")
        (value: builtins.stringLength value <= 253));
      default = null;
      description = "Public HTTPS hostname for the reference Nginx/ACME proxy. Null leaves web access closed for the SSH pilot; no DNS or cloud firewall is changed by this option.";
    };
    bedrockModelId = lib.mkOption {
      type = lib.types.str;
      default = "amazon.nova-micro-v1:0";
      description = "The same regional Bedrock model granted by the OpenTofu reference deployment.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [{
      assertion = builtins.all (path: lib.hasPrefix "/run/" path)
        [ cfg.environmentFile cfg.credentialKeyFile cfg.webSecretFile cfg.googleClientFile ];
      message = "Email Janitor secrets must be supplied at a runtime /run path, not put into the Nix store.";
    }];
    users.groups.emailjanitor = {};
    users.users.emailjanitor = { isSystemUser = true; group = "emailjanitor"; };
    services.postgresql = {
      enable = true;
      enableTCPIP = lib.mkDefault false;
      settings.listen_addresses = lib.mkForce "";
      ensureDatabases = [ "emailjanitor" ];
      ensureUsers = [{ name = "emailjanitor"; ensureDBOwnership = true; }];
    };
    services.nginx = lib.mkIf (cfg.publicHostname != null) {
      enable = true;
      virtualHosts.${cfg.publicHostname} = {
        forceSSL = true;
        enableACME = true;
        extraConfig = ''
          # OAuth callbacks contain one-use secrets in the request URI. Avoid
          # access logs and upstream-error request dumps for this dedicated host.
          access_log off;
          error_log /dev/null;
        '';
        locations."/".extraConfig = ''
          proxy_pass http://127.0.0.1:4000;
          proxy_http_version 1.1;
          proxy_set_header Host $host;
          proxy_set_header X-Forwarded-Proto $scheme;
          # Replace attacker-supplied values; the app trusts this header only
          # from its loopback proxy. Never append a forwarded chain.
          proxy_set_header X-Real-IP $remote_addr;
          proxy_set_header X-Forwarded-For "";
          proxy_set_header Forwarded "";
          proxy_set_header Connection "";
          proxy_read_timeout 120s;
        '';
      };
    };
    security.acme.acceptTerms = lib.mkIf (cfg.publicHostname != null) true;
    networking.firewall.allowedTCPPorts = lib.mkIf (cfg.publicHostname != null) [ 80 443 ];
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
        JANITOR_ENABLE_SELF_HOST = "1";
        JANITOR_WEB_PORT = "4000";
        JANITOR_CREDENTIAL_KEY_FILE = "%d/credential-key";
        JANITOR_SECRET_KEY_BASE_FILE = "%d/web-secret";
        JANITOR_GOOGLE_CLIENT_JSON_FILE = "%d/google-client.json";
        JANITOR_REPLY_PARSER_EXECUTABLE = "${cfg.replyParserPackage}/bin/emailjanitor-reply-parser";
        ERL_CRASH_DUMP = "/dev/null";
        RELEASE_TMP = "/run/emailjanitor/release";
        RELEASE_DISTRIBUTION = "none";
        AWS_REGION = "us-east-1";
        JANITOR_MODEL_PROVIDER = "bedrock";
        JANITOR_MODEL_ID = cfg.bedrockModelId;
      } // lib.optionalAttrs config.services.emailjanitor-google-token.enable {
        JANITOR_GOOGLE_TOKEN_FILE = "/run/emailjanitor-google-token/token.json";
      };
      serviceConfig = {
        Type = "simple";
        User = "emailjanitor";
        Group = "emailjanitor";
        ExecStart = "${cfg.package}/bin/email_janitor start";
        ExecStartPre = "${cfg.package}/bin/email_janitor eval 'EmailJanitor.SelfHost.Release.migrate()'";
        EnvironmentFile = cfg.environmentFile;
        LoadCredential = [
          "credential-key:${cfg.credentialKeyFile}"
          "web-secret:${cfg.webSecretFile}"
          "google-client.json:${cfg.googleClientFile}"
        ];
        WorkingDirectory = "/var/lib/emailjanitor";
        StateDirectory = "emailjanitor";
        StateDirectoryMode = "0700";
        RuntimeDirectory = "emailjanitor";
        RuntimeDirectoryMode = "0700";
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
        # Owner recovery reads boot_id and this application's process-start stat.
        ProcSubset = "all";
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
