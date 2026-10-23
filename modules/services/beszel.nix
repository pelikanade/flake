{
  # Beszel keeps a history of each host's CPU, memory, disk and containers. A
  # hub owns the web UI and the SQLite data; every monitored host runs an agent,
  # and the hub dials each agent over SSH on 45876. Agents therefore need only
  # the hub's public key, and no port has to be reachable from the internet.
  flake.modules.nixos.beszel-hub = {
    services.beszel.hub = {
      enable = true;
      host = "127.0.0.1";
      port = 8090;
    };
  };

  # The agent authenticates the hub by its public key, so nothing secret lives
  # in this repository: the private half stays in the hub's data directory.
  # `LISTEN` is per machine, because only hosts the hub reaches over the tailnet
  # need to listen beyond loopback.
  flake.modules.nixos.beszel-agent = {
    services.beszel.agent = {
      enable = true;
      environment.KEY = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGOwPvV/5+Evg5uYYwJsA1EzRzkAnd/JLXrOiZLSalni";
    };
  };
}
