{
  # Beszel keeps a history of each host's CPU, memory, disk and containers. The
  # hub owns the web UI and the SQLite data; every monitored host runs an agent
  # ([beszel-agent.nix](beszel-agent.nix)) that connects out to it over a
  # WebSocket, authenticated by one universal token.
  flake.modules.nixos.beszel-hub = {
    services.beszel.hub = {
      enable = true;

      # The tailnet reaches the UI directly; the firewall admits only 22, 80 and
      # 443 publicly, and Caddy publishes the same port at probe.nvirellia.im.
      host = "0.0.0.0";
      port = 8090;

      # Agents keep the WebSocket open. Without SSH fallback, a disconnected
      # agent is simply marked down instead of being dialled.
      environment.DISABLE_SSH = "true";
    };
  };
}
