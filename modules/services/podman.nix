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
          `runtimeApis`. Systemd owns each published socket as this account, which
          is then the only account that can open it; a runtime can still name a
          different client of its own. Null leaves every socket with its own
          runtime's account.
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
          which would hand the runtime to every local process. Systemd owns the
          published socket as the client instead, so the client's container
          matches the owner bits and every other account stays out.

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
                    Account that owns the published socket and connects to this
                    runtime's API. Only a container running as that account can
                    match the socket's owner bits.
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
          # user can drive another's.
          virtualisation.podman = {
            enable = true;
            defaultNetwork.settings.dns_enabled = true;
          };

          # A rootful API socket is root-equivalent container control, so this
          # host publishes none.
          systemd.sockets.podman.enable = false;

          # Docker CLI for the API clients that call it; it needs no socket here.
          environment.systemPackages = [ pkgs.docker-client ];
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
                SocketUser = api.client;
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

          systemd.tmpfiles.rules = lib.mapAttrsToList (
            _: api: "d ${builtins.dirOf api.socketPath} 0750 ${api.client} ${api.client} -"
          ) runtimeApis;
        })
      ];
    };
}
