{
  # The agent registers itself with the hub through one universal token, and the
  # hub creates a system for it on first connect, named after `SYSTEM_NAME`. The
  # agent listens on no port: `DISABLE_SSH` removes its SSH server, so only the
  # outbound WebSocket remains. `KEY` is the hub's public key, which the agent
  # still demands at startup even though it never serves SSH.
  flake.modules.nixos.beszel-agent =
    { config, ... }:
    {
      services.beszel.agent = {
        enable = true;

        environment = {
          KEY = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGOwPvV/5+Evg5uYYwJsA1EzRzkAnd/JLXrOiZLSalni";
          DISABLE_SSH = "true";
          SYSTEM_NAME = config.networking.hostName;
        };

        environmentFile = config.sops.templates."beszel-agent-env".path;
      };

      # The token authenticates every agent, so it is shared: both agent hosts
      # and the maintainer are recipients of this document.
      sops.secrets.beszel-universal-token = {
        format = "yaml";
        key = "universal_token";
        sopsFile = config.constants.resources.getSecretPath "beszel.yaml";
        restartUnits = [ "beszel-agent.service" ];
      };

      sops.templates."beszel-agent-env" = {
        content = "TOKEN=${config.sops.placeholder.beszel-universal-token}";
        restartUnits = [ "beszel-agent.service" ];
      };
    };
}
