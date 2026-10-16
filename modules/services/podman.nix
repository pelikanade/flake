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
      apiClient = config.virtualisation.podman.runtimeApiClient;
    in
    {
      # Several aspects compose this module — the machine and the Portainer
      # aspect among them; keep one identity so it is applied once.
      key = "podman";

      options.virtualisation.podman.runtimeApiClient = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Account whose containers drive every published runtime in
          `runtimeApis`. Systemd gives each published socket that account as its
          group, which is then the only account other than the runtime's own that
          can open it; a runtime can still name a different client of its own. The
          null default leaves every client at its runtime's own account, so a
          published socket admits that account alone.
        '';
      };

      options.virtualisation.podman.runtimeApis = lib.mkOption {
        default = { };
        description = ''
          Rootless Podman runtimes on this host whose Docker-compatible API is
          published on a fixed socket, keyed by the account that owns the runtime.

          A runtime cannot publish that socket itself. Its own API socket lives in
          its private runtime directory, and inside a rootless user namespace
          neither that socket's owner nor its group maps, so another account's
          container could only be authorized by the "other" permission bits —
          which would hand the runtime to every local process. Systemd holds the
          published socket for two parties instead, and `0660` is what leaves room
          for both: its owner is the runtime's own account — the account that
          serves the API — so that account's host processes reach it through the
          owner bits, including a process inside another service's sandbox, which
          has no other way to run a container; its group is the client, whose gid
          maps into that account's own container as container gid 0, so the
          client's container reaches it through the group bits. Every other
          account matches neither.

          The runtime's own module declares the entry; the account that drives it
          names itself in `runtimeApiClient`.
        '';
        type = lib.types.attrsOf (
          lib.types.submodule (
            { name, ... }:
            {
              options = {
                client = lib.mkOption {
                  type = lib.types.str;
                  default = if apiClient != null then apiClient else name;
                  defaultText = "the account named in `runtimeApiClient`, or the runtime's own";
                  description = ''
                    Account whose containers connect to this runtime's API. The
                    published socket's group is this account, so the client's
                    container matches those bits and no account outside it does.
                  '';
                };

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
          # Containers run rootless: each user drives Podman under their own uid
          # and reaches its Docker-compatible API on that user's own socket under
          # `/run/user/<uid>/podman`. Every user gets their own runtime, and no
          # user can drive another's; the published sockets below are the
          # deliberate exception, and each names the client it admits.
          virtualisation.podman = {
            enable = true;
            defaultNetwork.settings.dns_enabled = true;
          };

          # A rootful API socket is root-equivalent container control, so this
          # host publishes none.
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

          # Docker CLI for the API clients that call it; it needs no socket here.
          #
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
                # The runtime's own account keeps the owner bits: it is the
                # account that serves this API, and its own processes — one
                # inside the daemon's sandbox, say — have no other way to run a
                # container.
                SocketUser = name;
                # The client's container runs as the client account, whose gid
                # maps into it as container gid 0, so the group bits admit the
                # container without admitting any host account but this one.
                SocketGroup = api.client;
              };
            }
          ) runtimeApis;

          # Socket activation keeps the API server unstarted until the client
          # connects, and Podman answers on the descriptor systemd hands it, so
          # the runtime's account never creates the socket at all.
          systemd.services = lib.mapAttrs' (
            name: api:
            lib.nameValuePair "podman-api-${name}" {
              description = "Podman API of the ${name} runtime";
              requires = [ api.socketUnit ];
              after = [
                api.socketUnit
                # Both parties run rootless, and a lingering user manager is what
                # lets Podman keep containers in that user's cgroups; it falls
                # back to cgroupfs until one is up.
                "linger-users.service"
              ];
              serviceConfig = {
                User = name;
                Group = name;
                Type = "exec";
                # Containers this API starts manage their own cgroups, as
                # upstream's own service unit does.
                Delegate = true;
                KillMode = "process";
                ExecStart = "${lib.getExe' config.virtualisation.podman.package "podman"} system service";
                Restart = "on-failure";
              };
            }
          ) runtimeApis;

          # The directory follows the socket: the runtime's account owns it, the
          # client reaches through the group, and no third account traverses it.
          systemd.tmpfiles.rules = lib.mapAttrsToList (
            name: api: "d ${builtins.dirOf api.socketPath} 0750 ${name} ${api.client} -"
          ) runtimeApis;
        })
      ];
    };
}
