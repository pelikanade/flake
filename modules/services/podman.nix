{
  flake.modules.nixos.podman =
    { pkgs, ... }:
    {
      # Podman serves the Docker-compatible socket below, so the real Docker
      # client talks to it without pulling in the dockerd daemon.
      environment.systemPackages = [ pkgs.docker-client ];

      virtualisation = {
        podman = {
          enable = true;
          dockerSocket.enable = true;
          defaultNetwork.settings.dns_enabled = true;
        };
      };
    };
}
