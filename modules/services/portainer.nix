{
  inputs,
  ...
}:
{
  # Portainer runs in its own rootless Podman; the Podman aspect supplies that
  # runtime and the published API sockets this service mounts.
  flake.modules.aspects.portainer.imports = [ inputs.self.modules.aspects.podman ];

  # The vendor ships no nixpkgs package for Portainer, so the service runs its
  # image under NixOS-managed lifecycle, storage, exposure, and sockets. It is the
  # host's container UI: it drives every published runtime and declares its own,
  # so it holds containers itself as well.
  flake.modules.nixos.portainer =
    {
      config,
      lib,
      ...
    }:
    let
      account = "portainer";
      runtimeApis = config.virtualisation.podman.runtimeApis;
      # The runtime this container runs in is Portainer's local environment; every
      # other published runtime arrives as its own environment.
      localSocket = runtimeApis.${account}.socketPath;
    in
    {
      virtualisation.podman = {
        runtimeApiClient = account;
        runtimeApis.${account} = { };
      };

      users.groups.${account} = { };
      users.users.${account} = {
        # Rootless Podman needs a subordinate ID range, and a lingering user
        # manager owns `/run/user/<uid>` and everything the runtime keeps there.
        isSystemUser = true;
        group = account;
        autoSubUidGidRange = true;
        linger = true;
        home = "/var/lib/portainer";
        createHome = true;
        homeMode = "0700";
      };

      systemd.tmpfiles.rules = [ "d /var/lib/portainer/data 0700 ${account} ${account} -" ];

      virtualisation.oci-containers = {
        backend = "podman";

        containers.portainer = {
          image = "portainer/portainer-ce:2.45.2";
          podman.user = account;
          # Podman's rootless port forwarding runs as the account, so 9443 is an
          # ordinary host socket and the firewall rule below decides who reaches
          # it. The image's own HTTP listener and edge tunnel stay unpublished.
          ports = [ "9443:9443" ];
          volumes = [
            "${localSocket}:/var/run/docker.sock"
            "/var/lib/portainer/data:/data"
          ]
          ++ lib.mapAttrsToList (name: api: "${api.socketPath}:/run/podman-${name}.sock") (
            lib.removeAttrs runtimeApis [ account ]
          );
        };
      };

      # Podman refuses a bind mount whose source is missing, so every socket has
      # to exist before the container is created. Their units are part of
      # sockets.target; this ordering guarantees it for the first start.
      systemd.services.podman-portainer = {
        after = lib.mapAttrsToList (_: api: api.socketUnit) runtimeApis;
        requires = lib.mapAttrsToList (_: api: api.socketUnit) runtimeApis;
        # The oci-containers module derives this from the running account's uid,
        # which NixOS assigns during activation rather than during evaluation.
        # Nothing here mounts the account's runtime directory: the sockets the
        # container uses live outside it, and lingering logind owns the rest.
        unitConfig.RequiresMountsFor = lib.mkForce [ ];
      };

      # Reachable on the tailnet and on loopback only. `tailnet0` is the system
      # interface of the sing-box Tailscale endpoint, which this host imports.
      networking.firewall.interfaces.tailnet0.allowedTCPPorts = [ 9443 ];
    };
}
