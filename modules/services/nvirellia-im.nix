{
  flake.modules.nixos.nvirellia-im =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib)
        mkOption
        optional
        optionalAttrs
        types
        ;

      cfg = config.services.nvirellia-im;
    in
    {
      options.services.nvirellia-im = {
        package = mkOption {
          type = types.package;
          default = pkgs.selfPackages.nvirellia-im;
          defaultText = lib.literalExpression "pkgs.selfPackages.nvirellia-im";
          description = "The nvirellia-im package to use.";
        };

        listenAddress = mkOption {
          type = types.str;
          default = "127.0.0.1";
          example = "0.0.0.0";
          description = ''
            Address to bind. Write IPv6 addresses with brackets, for example `"[::]"`.
          '';
        };

        port = mkOption {
          type = types.port;
          default = 8080;
          description = "TCP port to listen on.";
        };

        feedTTL = mkOption {
          type = types.str;
          default = "30s";
          example = "2m";
          description = "How long a magpie response stays fresh before it is fetched again (`FEED_TTL`).";
        };

        magpie = {
          url = mkOption {
            type = types.nullOr types.str;
            default = null;
            example = "http://magpie.example:8081";
            description = ''
              Base URL of the magpie instance. When null, the sheet renders without
              the Resources panel.
            '';
          };

          keyFile = mkOption {
            type = types.nullOr types.str;
            default = null;
            example = "/run/secrets/magpie-web-key";
            description = ''
              File holding `MAGPIE_WEB_KEY=...` for magpie's web API. systemd reads it
              before the service drops privileges, so it may be root-only. Required
              when {option}`services.nvirellia-im.magpie.url` is set.
            '';
          };
        };

        gatus = {
          url = mkOption {
            type = types.nullOr types.str;
            default = null;
            example = "http://127.0.0.1:3001";
            description = ''
              Base URL of the gatus instance whose uptime checks fill the Status
              tab. When null, the uptime half of the tab is omitted.
            '';
          };
        };

        prometheus = {
          url = mkOption {
            type = types.nullOr types.str;
            default = null;
            example = "http://127.0.0.1:9090";
            description = ''
              Base URL of the Prometheus HTTP API whose node probes fill the Status
              tab. When null, the probe half of the tab is omitted.
            '';
          };

          job = mkOption {
            type = types.str;
            default = "node";
            example = "node";
            description = ''
              Scrape job holding the node_exporter targets (`PROMETHEUS_JOB`). The
              targets should carry a `host` label with the display name.
            '';
          };

          flakeRepository = mkOption {
            type = types.str;
            default = "pelikanade/flake";
            example = "pelikanade/flake";
            description = ''
              GitHub repository (`owner/repo`) whose `main` head marks a host's
              revision up to date (`FLAKE_REPO`). Only used when
              {option}`services.nvirellia-im.prometheus.url` is set.
            '';
          };
        };

        openFirewall = lib.mkEnableOption "opening the configured port in the firewall";
      };

      config = {
        services.nvirellia-im = {
          magpie.url = "http://${config.constants.getTailnetFqdn "nsphere-magpie"}";
          magpie.keyFile = config.sops.templates.nvirellia-im-environment.path;

          gatus.url = "http://127.0.0.1:3001";
          prometheus.url = "http://127.0.0.1:9090";
        };

        assertions = [
          {
            assertion = cfg.magpie.url == null || cfg.magpie.keyFile != null;
            message = "services.nvirellia-im.magpie.keyFile is required when magpie.url is set.";
          }
          {
            assertion = cfg.magpie.keyFile == null || cfg.magpie.url != null;
            message = "services.nvirellia-im.magpie.keyFile has no effect without magpie.url.";
          }
          {
            assertion = cfg.prometheus.url == null || cfg.prometheus.job != "";
            message = "services.nvirellia-im.prometheus.job must not be empty.";
          }
          {
            assertion = cfg.prometheus.url == null || cfg.prometheus.flakeRepository != "";
            message = "services.nvirellia-im.prometheus.flakeRepository must not be empty.";
          }
        ];

        networking.firewall.allowedTCPPorts = optional cfg.openFirewall cfg.port;

        systemd.services.nvirellia-im = {
          description = "nvirellia.im profile sheet";
          wantedBy = [ "multi-user.target" ];
          after = [ "network.target" ];

          environment = {
            LISTEN_ADDR = "${cfg.listenAddress}:${toString cfg.port}";
            FEED_TTL = cfg.feedTTL;
          }
          // optionalAttrs (cfg.magpie.url != null) {
            MAGPIE_URL = cfg.magpie.url;
          }
          // optionalAttrs (cfg.gatus.url != null) {
            GATUS_URL = cfg.gatus.url;
          }
          // optionalAttrs (cfg.prometheus.url != null) {
            PROMETHEUS_URL = cfg.prometheus.url;
            PROMETHEUS_JOB = cfg.prometheus.job;
            FLAKE_REPO = cfg.prometheus.flakeRepository;
          };

          serviceConfig = {
            ExecStart = "${cfg.package}/bin/nvirellia-im";
            EnvironmentFile = optional (cfg.magpie.keyFile != null) cfg.magpie.keyFile;

            DynamicUser = true;
            StateDirectory = "nvirellia-im";
            WorkingDirectory = "/var/lib/nvirellia-im";

            AmbientCapabilities = optional (cfg.port < 1024) "CAP_NET_BIND_SERVICE";

            Restart = "on-failure";
            RestartSec = 5;

            NoNewPrivileges = true;
            PrivateDevices = true;
            PrivateTmp = true;
            ProtectHome = true;
            ProtectSystem = "strict";
            RestrictSUIDSGID = true;
          };
        };

        # The unit loads the key through `EnvironmentFile`, which systemd reads
        # before it drops to the dynamic user, so root-only is enough.
        sops.secrets."magpie-web-key" = {
          format = "yaml";
          key = "magpie_web_key";
          sopsFile = config.constants.resources.getSecretPath "magpie.yaml";
          restartUnits = [ "nvirellia-im.service" ];
        };

        sops.templates.nvirellia-im-environment = {
          content = "MAGPIE_WEB_KEY=${config.sops.placeholder."magpie-web-key"}";
          restartUnits = [ "nvirellia-im.service" ];
        };
      };
    };
}
