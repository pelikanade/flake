{
  flake.modules.nixos.avalanche =
    {
      config,
      lib,
      options,
      pkgs,
      ...
    }:
    let
      triggerDir = "/run/deploy-trigger";
      triggerPort = 8080;
      avalanche = pkgs.selfPackages.avalanche;

      serverYaml = (pkgs.formats.yaml { }).generate "server.yaml" {
        server = {
          hostname = config.networking.hostName;
          token_file = config.sops.secrets.deploy_trigger_token.path;
          dir = triggerDir;
          port = triggerPort;
          timeout = "2h";
        };
      };

      clientYaml = (pkgs.formats.yaml { }).generate "client.yaml" {
        client = {
          tailnet = config.constants.tailnetDnsName;
          token_file = "/run/secrets/deploy_trigger_token";
          port = 8080;
          flake = ".";
          timeout = "2h";
        };
      };

      hasRunner =
        builtins.hasAttr "github-runners" config.services && config.services.github-runners != { };
    in
    {
      config = lib.mkMerge [
        {
          environment.etc."avalanche/server.yaml".source = serverYaml;

          users.groups.deploy = { };
          users.groups.deploy-trigger = { };

          users.users.deploy-trigger = {
            isSystemUser = true;
            group = "deploy-trigger";
            extraGroups = [ "deploy" ];
            description = "Deployment trigger service";
          };

          sops.secrets.deploy_trigger_token = {
            sopsFile = ../secrets/deploy-trigger.yaml;
            key = "deploy_trigger_token";
            owner = "root";
            group = "deploy";
            mode = "0440";
            restartUnits = [ "deploy-trigger.service" ];
          };

          systemd.services.deploy-trigger = {
            description = "Authenticated pull-based deployment trigger";
            wantedBy = [ "multi-user.target" ];
            after = [ "network.target" ];
            serviceConfig = {
              User = "deploy-trigger";
              Group = "deploy-trigger";
              SupplementaryGroups = [ "deploy" ];
              RuntimeDirectory = "deploy-trigger";
              RuntimeDirectoryMode = "0700";
              ExecStart = "${avalanche}/bin/avalanche-server serve";
              Restart = "always";
              RestartSec = 2;
              NoNewPrivileges = true;
              PrivateTmp = true;
              ProtectHome = true;
              ProtectSystem = "strict";
              PrivateDevices = true;
              ProtectKernelTunables = true;
              ProtectKernelModules = true;
              ProtectControlGroups = true;
              RestrictNamespaces = true;
              RestrictAddressFamilies = [
                "AF_INET"
                "AF_INET6"
                "AF_UNIX"
              ];
              RestrictSUIDSGID = true;
              LockPersonality = true;
              SystemCallArchitectures = "native";
              UMask = "0077";
            };
          };

          systemd.services.nixos-deploy = {
            description = "Activate a triggered NixOS closure";
            after = [ "deploy-trigger.service" ];
            requires = [ "deploy-trigger.service" ];
            serviceConfig = {
              Type = "oneshot";
              ExecStart = "${avalanche}/bin/avalanche-server request";
              Environment = [
                "PATH=/run/current-system/sw/bin"
              ];
              TimeoutStartSec = "5m";
            };
          };

          systemd.paths.nixos-deploy = {
            description = "Watch for a deployment request";
            wantedBy = [ "multi-user.target" ];
            after = [ "deploy-trigger.service" ];
            requires = [ "deploy-trigger.service" ];
            pathConfig = {
              PathChanged = "${triggerDir}/request";
              Unit = "nixos-deploy.service";
            };
          };

          systemd.services.tailscale-serve-deploy =
            lib.mkIf (options.services ? tailscale && config.services.tailscale.enable)
              {
                description = "Publish the deployment trigger on the tailnet";
                wantedBy = [ "multi-user.target" ];
                wants = [ "tailscaled.service" ];
                after = [
                  "tailscaled.service"
                  "tailscaled-autoconnect.service"
                  "deploy-trigger.service"
                ];
                serviceConfig = {
                  Type = "oneshot";
                  RemainAfterExit = true;
                  ExecStart = "${pkgs.tailscale}/bin/tailscale serve --bg --http=${toString triggerPort} ${toString triggerPort}";
                };
              };
        }

        (lib.mkIf hasRunner {
          environment.etc."avalanche/client.yaml".source = clientYaml;
          environment.systemPackages = [ avalanche ];
        })
      ];
    };
}
