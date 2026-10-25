{
  flake.modules.nixos.podman =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      runtimeApis = config.virtualisation.podman.runtimeApis;
    in
    {
      key = "podman";

      options.virtualisation.podman.runtimeApis = lib.mkOption {
        default = { };
        description = ''
          Rootless Podman runtimes on this host whose Docker-compatible API is
          published on a fixed socket, keyed by the account that owns the runtime.

          A runtime's own API socket lives in its private runtime directory, which
          a process inside another service's sandbox may not be able to reach. The
          published socket lives outside that directory and is owned by the
          runtime's own account, so that account's processes reach it through the
          owner bits, including from inside a sandbox. Mode `0660` with the same
          account as its group leaves no other account able to open it.

          The runtime's own module declares the entry.
        '';
        type = lib.types.attrsOf (
          lib.types.submodule (
            { name, ... }:
            {
              options = {
                socketPath = lib.mkOption {
                  type = lib.types.str;
                  readOnly = true;
                  description = ''
                    Published API socket, outside the runtime account's private
                    runtime directory, so that the client's container can mount
                    it.
                  '';
                };

                socketUnit = lib.mkOption {
                  type = lib.types.str;
                  readOnly = true;
                  description = "Systemd socket unit holding the published API socket.";
                };
              };

              config = {
                socketPath = "/run/podman-api-${name}/podman.sock";
                socketUnit = "podman-api-${name}.socket";
              };
            }
          )
        );
      };

      config = lib.mkMerge [
        {
          virtualisation.podman = {
            enable = true;
            defaultNetwork.settings.dns_enabled = true;
          };

          systemd.sockets.podman.enable = false;

          # A rootless runtime has no boot path of its own. A restart policy
          # tells conmon to respawn a container whose process dies while its
          # manager runs, and nothing in a user manager starts one at boot, so a
          # container an account started by hand, from a compose file, or through
          # a published API socket stays exited until something starts it again.
          # Upstream's `podman-restart.service` is that boot path — it starts
          # every container whose policy asks for it — and Podman's package
          # publishes it into `/etc/systemd/user`, which nixpkgs links without
          # enabling: only `podman.socket` gets a want of its own. The
          # `default.target` want below is what enables it, and every account's
          # manager reaches `default.target` when it comes up.
          #
          # A user manager cannot see the system's `network-online.target`, so
          # the gate is the wait unit upstream's own Quadlet path uses: it polls
          # the system's target and holds the restart until the network a
          # container may publish on, or pull an image over, is up.
          systemd.user.services.podman-restart = {
            wantedBy = [ "default.target" ];
            wants = [ "podman-user-wait-network-online.service" ];
            after = [ "podman-user-wait-network-online.service" ];
          };

          # `podman compose` is a wrapper that execs a provider, so a provider has
          # to be on PATH: `docker-compose` wins the wrapper's lookup over
          # `podman-compose`, and it drives these runtimes over the same
          # Docker-compatible API the CLI above uses. The wrapper passes an
          # existing `DOCKER_HOST` through unchanged, which is what the Paseo
          # daemon sets for its agents; without one it would hand the provider the
          # account's own socket path instead.
          environment.systemPackages = [
            pkgs.docker-client
            pkgs.docker-compose
          ];
        }

        (lib.mkIf (runtimeApis != { }) {
          systemd.sockets = lib.mapAttrs' (
            name: api:
            lib.nameValuePair "podman-api-${name}" {
              description = "Podman API socket of the ${name} runtime";
              wantedBy = [ "sockets.target" ];
              socketConfig = {
                ListenStream = api.socketPath;
                SocketMode = "0660";
                SocketUser = name;
                SocketGroup = name;
              };
            }
          ) runtimeApis;

          systemd.services = lib.mapAttrs' (
            name: api:
            lib.nameValuePair "podman-api-${name}" {
              description = "Podman API of the ${name} runtime";
              requires = [ api.socketUnit ];
              after = [
                api.socketUnit
                # The API server runs rootless, and a lingering user manager is
                # what lets Podman keep containers in that user's cgroups; it
                # falls back to cgroupfs until one is up.
                "linger-users.service"
              ];
              serviceConfig = {
                User = name;
                Group = name;
                Type = "exec";
                Delegate = true;
                KillMode = "process";
                ExecStart = "${lib.getExe' config.virtualisation.podman.package "podman"} system service";
                Restart = "on-failure";
              };
            }
          ) runtimeApis;

          systemd.tmpfiles.rules = lib.mapAttrsToList (
            name: api: "d ${builtins.dirOf api.socketPath} 0750 ${name} ${name} -"
          ) runtimeApis;
        })
      ];
    };
}
