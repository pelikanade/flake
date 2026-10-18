{
  flake.modules.nixos.tailscale-ingress =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      services = config.services.tailscale-ingress.services;
      tailscale = lib.getExe config.services.tailscale.package;

      # The configuration file is the whole declaration for this host: `set-config
      # --all` replaces every Service's endpoints, so an entry removed here stops
      # being forwarded. Node-level Serve and Funnel entries live in a different
      # part of the daemon's state and are left alone.
      serviceConfig = pkgs.writeText "tailscale-services.json" (
        builtins.toJSON {
          version = "0.0.1";
          services = lib.mapAttrs' (
            name: service:
            lib.nameValuePair "svc:${name}" {
              inherit (service) endpoints;
              advertised = true;
            }
          ) services;
        }
      );
    in
    {
      options.services.tailscale-ingress.services = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule {
            options.endpoints = lib.mkOption {
              type = lib.types.attrsOf lib.types.str;
              example = {
                "tcp:443" = "http://127.0.0.1:8080";
              };
              description = ''
                Incoming endpoint to local target, as Tailscale's Service
                configuration file maps them. The key is `tcp:<port>` and must
                match an endpoint the Service was defined with in the tailnet.
                The value's scheme chooses the handler: `http` or `https` is an
                HTTPS reverse proxy that terminates the tailnet certificate,
                `https+insecure` does the same without verifying the upstream's
                certificate, and `tcp` forwards the connection unmodified.
              '';
            };
          }
        );
        default = { };
        description = ''
          The Tailscale Services this host advertises, keyed by name without the
          `svc:` prefix: `services.foo` advertises `svc:foo`, which the tailnet
          answers at `foo.<tailnetDnsName>`. The service names, their endpoints
          and their tags are defined in the tailnet's admin console; this option
          only says where each endpoint's traffic goes on this host.

          A Service host must have a tagged, not user-owned, node identity, and
          a new host advertisement needs approval unless an auto-approver covers
          it.
        '';
      };

      config = lib.mkIf (services != { }) {
        systemd.services.tailscale-serve = {
          description = "Advertise this host's Tailscale Services";
          wantedBy = [ "multi-user.target" ];
          wants = [ "tailscaled.service" ];
          after = [
            "network-online.target"
            "tailscaled.service"
            "tailscaled-autoconnect.service"
          ];

          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            TimeoutStartSec = 600;

            # `set-config` needs a node that is logged in. The unit starts after
            # the autoconnect helper, but the daemon's backend can still be
            # settling on a slow boot, so wait for it rather than fail the
            # advertisement until the next switch.
            ExecStart = pkgs.writeShellScript "tailscale-serve" ''
              set -euo pipefail

              tries=0
              until ${tailscale} status --json 2>/dev/null \
                | ${lib.getExe pkgs.jq} -e '.BackendState == "Running"' >/dev/null; do
                tries=$((tries + 1))
                if [ "$tries" -ge 60 ]; then
                  echo "tailscaled is not Running; cannot advertise Services" >&2
                  exit 1
                fi
                sleep 2
              done

              # `--all` also replaces the node's advertised-service list with
              # the entries marked `advertised` in this file, so a removed entry
              # stops being advertised too.
              ${tailscale} serve set-config --all ${serviceConfig}
            '';
          };
        };

        # A daemon restart drops the host's advertisements even though its
        # configuration survives, so start the advertisement again alongside it.
        systemd.services.tailscaled.upholds = [ "tailscale-serve.service" ];
      };
    };
}
