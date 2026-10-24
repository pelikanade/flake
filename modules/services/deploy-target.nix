{
  flake.modules.nixos.deploy-target =
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

      triggerScript = pkgs.writeText "deploy-trigger.py" ''
        import hmac
        import http.server
        import os
        import pathlib
        import re
        import secrets
        import time

        token = pathlib.Path(os.environ["DEPLOY_TRIGGER_TOKEN_FILE"]).read_text().strip()
        request_dir = pathlib.Path(os.environ["DEPLOY_TRIGGER_DIR"])
        hostname = os.environ["DEPLOY_TARGET_HOSTNAME"]
        port = int(os.environ["DEPLOY_TRIGGER_PORT"])
        timeout = int(os.environ["DEPLOY_TRIGGER_TIMEOUT"])
        store_path = re.compile(
            rf"^/nix/store/[a-z0-9]{{32}}-nixos-system-{re.escape(hostname)}(-[^/]+)?$"
        )

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def do_POST(self):
                if self.path != "/deploy":
                    self.send_error(404)
                    return
                expected = "Bearer " + token
                if not hmac.compare_digest(self.headers.get("Authorization", ""), expected):
                    self.send_error(403)
                    return
                length = int(self.headers.get("Content-Length", "0"))
                body = self.rfile.read(length).decode("utf-8", "replace").strip()
                if not store_path.match(body):
                    self.send_error(400, "invalid store path")
                    return

                nonce = secrets.token_hex(8)
                request = request_dir / "request"
                tmp = request_dir / f".request-{nonce}"
                tmp.write_text(f"{nonce} {body}\n")
                tmp.replace(request)

                result = request_dir / f"result-{nonce}"
                deadline = time.monotonic() + timeout
                while time.monotonic() < deadline:
                    if result.exists():
                        status = result.read_text().strip()
                        result.unlink(missing_ok=True)
                        self.send_response(200 if status == "ok" else 500)
                        self.send_header("Content-Length", "0")
                        self.end_headers()
                        return
                    time.sleep(1)
                self.send_error(504, "deployment timed out")

            def log_message(self, format, *args):
                pass

        server = http.server.HTTPServer(("127.0.0.1", port), Handler)
        server.serve_forever()
      '';

      deployRun = pkgs.writeShellApplication {
        name = "nixos-deploy-run";
        runtimeInputs = [
          config.nix.package
          pkgs.coreutils
        ];
        text = ''
          set -euo pipefail

          nonce="''${1:?nonce required}"
          store_path="''${2:?store path required}"
          result="${triggerDir}/result-$nonce"

          trap 'printf "failed\n" > "$result"; chmod 0644 "$result"' ERR

          nix-store --realise "$store_path" --option max-jobs 0
          nix-env -p /nix/var/nix/profiles/system --set "$store_path"
          "$store_path/bin/switch-to-configuration" switch
          printf 'ok\n' > "$result"
          chmod 0644 "$result"
        '';
      };

      deployTrigger = pkgs.writeShellApplication {
        name = "nixos-deploy-trigger-request";
        runtimeInputs = [
          config.nix.package
          pkgs.coreutils
          pkgs.systemd
        ];
        text = ''
          set -euo pipefail

          request="${triggerDir}/request"
          [ -f "$request" ] || exit 0
          read -r nonce store_path < "$request"
          rm -f "$request"

          trap 'printf "failed\n" > "${triggerDir}/result-$nonce"; chmod 0644 "${triggerDir}/result-$nonce"' ERR

          systemd-run \
            --unit="nixos-deploy-run-$nonce" \
            --collect \
            --property=Type=oneshot \
            --property=TimeoutStartSec=2h \
            --property=TimeoutStopSec=2h \
            --setenv=PATH=/run/current-system/sw/bin \
            "${deployRun}/bin/nixos-deploy-run" "$nonce" "$store_path"
        '';
      };
    in
    {
      options.services.deploy-target.enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether this host accepts pull-based deployment triggers.";
      };

      config = lib.mkIf config.services.deploy-target.enable {
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
            ExecStart = "${pkgs.python3}/bin/python3 ${triggerScript}";
            Restart = "always";
            RestartSec = 2;
            Environment = [
              "DEPLOY_TRIGGER_TOKEN_FILE=${config.sops.secrets.deploy_trigger_token.path}"
              "DEPLOY_TRIGGER_DIR=${triggerDir}"
              "DEPLOY_TARGET_HOSTNAME=${config.networking.hostName}"
              "DEPLOY_TRIGGER_PORT=${toString triggerPort}"
              "DEPLOY_TRIGGER_TIMEOUT=7200"
            ];
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
            ExecStart = "${deployTrigger}/bin/nixos-deploy-trigger-request";
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
      };
    };
}
