{
  # Prometheus scrapes node_exporter on every host, and the profile sheet reads
  # the same read-only HTTP API. Targets and their host labels live in Nix, so
  # there is no dashboard database or per-host login to keep in sync.
  #
  # The hub binds to loopback; the agents listen on every interface but their
  # port is closed publicly. The tailnet interface is trusted, which is how the
  # hub reaches its peers.
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

  flake.modules.nixos.probe-agent = {
    services.prometheus.exporters.node = {
      enable = true;

      # The tailnet is a trusted interface; the public firewall drops this port.
      listenAddress = "0.0.0.0";
      openFirewall = false;
    };
  };
}
