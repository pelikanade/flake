{
  flake.modules.nixos.docker =
    {
      pkgs,
      ...
    }:
    {
      key = "docker";

      config = {
        virtualisation.docker.enable = true;

        # The daemon's own package puts `docker` on PATH; the standalone compose
        # binary lets clients that invoke `docker-compose` drive the same socket.
        environment.systemPackages = [
          pkgs.docker-compose
        ];
      };
    };
}
