{ inputs, ... }:
{
  flake.modules.aspects.paseo-docker.imports = with inputs.self.modules.aspects; [
    docker
    paseo-daemon
  ];

  flake.modules.nixos.paseo-docker = {
    # OpenSandbox runs as paseo on the host. Docker access is root-equivalent;
    # sandbox workloads must never inherit this socket or host bind mounts.
    users.users.paseo.extraGroups = [ "docker" ];
    systemd.services.paseo-daemon = {
      wants = [ "docker.service" ];
      after = [ "docker.service" ];
      # Put access in the unit too, so activation restarts it with the new group.
      serviceConfig.SupplementaryGroups = [ "docker" ];
    };
  };
}
