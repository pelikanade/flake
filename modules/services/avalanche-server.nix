{
  flake.modules.nixos.avalanche-server =
    {
      config,
      lib,
      options,
      pkgs,
      ...
    }:
    let
      triggerDir = "/run/avalanche";
      triggerPort = 8080;
      avalanche = pkgs.selfPackages.avalanche;

      serverYaml = (pkgs.formats.yaml { }).generate "server.yaml" {
        server = {
          hostname = config.networking.hostName;
          token_file = config.sops.secrets.avalanche_token.path;
          dir = triggerDir;
          port = triggerPort;
          timeout = "2h";
        };
      };
    in
    {
      config = {
        environment.etc."avalanche/server.yaml".source = serverYaml;

        users.groups.avalanche = { };

        users.users.avalanche = {
          isSystemUser = true;
          group = "avalanche";
          description = "Avalanche server";
        };

        sops.secrets.avalanche_token = {
          sopsFile = ../secrets/avalanche.yaml;
          key = "token";
          owner = "root";
          group = "avalanche";
          mode = "0440";
          restartUnits = [ "avalanche-server.service" ];
        };

        systemd.services.avalanche-server = {
          description = "Authenticated pull-based deployment trigger";
          wantedBy = [ "multi-user.target" ];
          after = [ "network.target" ];
          serviceConfig = {
            User = "avalanche";
            Group = "avalanche";
            RuntimeDirectory = "avalanche";
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

        systemd.services.avalanche-deploy = {
          description = "Activate a triggered NixOS closure";
          after = [ "avalanche-server.service" ];
          requires = [ "avalanche-server.service" ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${avalanche}/bin/avalanche-server request";
            Environment = [
              "PATH=/run/current-system/sw/bin"
            ];
            TimeoutStartSec = "5m";
          };
        };

        systemd.paths.avalanche-deploy = {
          description = "Watch for a deployment request";
          wantedBy = [ "multi-user.target" ];
          after = [ "avalanche-server.service" ];
          requires = [ "avalanche-server.service" ];
          pathConfig = {
            PathChanged = "${triggerDir}/request";
            Unit = "avalanche-deploy.service";
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
                "avalanche-server.service"
              ];
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
                ExecStart = "${pkgs.tailscale}/bin/tailscale serve --bg --http=${toString triggerPort} ${toString triggerPort}";
              };
            };
      };
    };
}
