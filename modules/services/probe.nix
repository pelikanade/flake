{ inputs, ... }:
{
  flake.modules.nixos.probe-hub =
    { config, lib, ... }:
    let
      cfg = config.services.probe;
    in
    {
      options.services.probe.targets = lib.mkOption {
        type = lib.types.listOf (
          lib.types.submodule {
            options = {
              name = lib.mkOption {
                type = lib.types.str;
                description = "Value for the target's host label, and the name the site shows.";
              };
              address = lib.mkOption {
                type = lib.types.str;
                description = "Host name or address Prometheus dials.";
              };
              port = lib.mkOption {
                type = lib.types.port;
                default = 9100;
                description = "node_exporter port.";
              };
            };
          }
        );
        default = [ ];
        description = "Hosts whose node_exporter Prometheus scrapes.";
      };

      config.services.prometheus = {
        enable = true;
        listenAddress = "127.0.0.1";
        port = 9090;
        scrapeConfigs = [
          {
            job_name = "node";
            static_configs = map (target: {
              targets = [ "${target.address}:${toString target.port}" ];
              labels.host = target.name;
            }) cfg.targets;
          }
        ];
      };
    };

  flake.modules.nixos.probe-agent =
    { pkgs, ... }:
    let
      # A clean checkout carries `rev`; an edited one carries `dirtyRev` with a
      # `-dirty` suffix. A tree Nix cannot attribute, such as a linked worktree,
      # has neither, and the metric says so rather than inventing a revision.
      revision = inputs.self.dirtyRev or inputs.self.rev or "unknown";

      metricsDirectory = "/run/probe";
    in
    {
      services.prometheus.exporters.node = {
        enable = true;

        listenAddress = "0.0.0.0";
        openFirewall = false;

        enabledCollectors = [ "textfile" ];
        extraFlags = [ "--collector.textfile.directory=${metricsDirectory}" ];
      };

      systemd.services.probe-metrics = {
        description = "Publish this host's flake revision to node_exporter";
        wantedBy = [ "multi-user.target" ];
        before = [ "prometheus-node-exporter.service" ];
        path = [ pkgs.coreutils ];

        serviceConfig.Type = "oneshot";

        script = ''
          set -euo pipefail

          updated=$(stat -c %Y /nix/var/nix/profiles/system)

          install -d -m 0755 ${metricsDirectory}
          tmp=$(mktemp ${metricsDirectory}/.nixos.XXXXXX)
          trap 'rm -f "$tmp"' EXIT

          cat > "$tmp" <<EOF
          # HELP nixos_flake_info Flake revision the running system was built from.
          # TYPE nixos_flake_info gauge
          nixos_flake_info{revision="${revision}"} 1
          # HELP nixos_system_update_time_seconds Unix time at which the running system generation was activated.
          # TYPE nixos_system_update_time_seconds gauge
          nixos_system_update_time_seconds $updated
          EOF

          chmod 0644 "$tmp"
          mv "$tmp" ${metricsDirectory}/nixos.prom
        '';
      };

      systemd.timers.probe-metrics = {
        wantedBy = [ "timers.target" ];
        timerConfig.OnCalendar = "*:0/5";
      };
    };
}
