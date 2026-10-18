{
  flake.modules.nixos.netbird-userspace =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.services.netbird-userspace;

      # A userspace (netstack) client: WireGuard runs on a Go TCP/IP stack
      # instead of a TUN device, so an unprivileged service user runs it, and it
      # touches no interface, route, resolver entry or firewall rule of the host.
      # Its only opening is a SOCKS5 proxy on loopback, which is what the
      # tunnels below dial; see docs/netbird-userspace.md.
      netbird = pkgs.unstable.netbird;

      # The endpoint and the setup key are data in this feature's own encrypted
      # document, so neither is a repository value and neither reaches the Nix
      # store. netbird reads the endpoint from an environment variable, so a
      # wrapper hands it over from the provisioned file wherever a login runs;
      # the client itself stores it in its profile at registration, which is what
      # the daemon reads afterwards.
      managementUrl = config.sops.secrets."netbird-userspace-management-url".path;
      setupKey = config.sops.secrets."netbird-userspace-setup-key".path;

      stateDir = "/var/lib/netbird-userspace";
      socksPort = 1080;
      daemonAddr = "unix:///run/netbird-userspace/sock";

      clientEnv = {
        NB_USE_NETSTACK_MODE = "true";
        NB_SOCKS5_LISTENER_PORT = toString socksPort;
        NB_STATE_DIR = stateDir;
        NB_DAEMON_ADDR = daemonAddr;
        # An unprivileged daemon cannot create /var/log/netbird and refuses to
        # start without a writable log, so it logs to the journal instead.
        NB_LOG_FILE = "console";
      }
      // lib.optionalAttrs (cfg.hostname != null) { NB_HOSTNAME = cfg.hostname; };

      envLines = lib.concatLines (
        lib.mapAttrsToList (name: value: "export ${name}=${lib.escapeShellArg value}") clientEnv
      );

      endpointWrapper = pkgs.writeShellScript "netbird-userspace-endpoint" ''
        export NB_MANAGEMENT_URL="$(${lib.getExe' pkgs.coreutils "cat"} ${managementUrl})"
        exec "$@"
      '';

      cli = pkgs.writeShellScriptBin "netbird-userspace" ''
        ${envLines}
        exec ${endpointWrapper} ${lib.getExe netbird} "$@"
      '';

      # socat terminates the loopback connection and dials the target through the
      # client's SOCKS5 proxy, which is unauthenticated and loopback-only:
      # neither listener is reachable from the LAN.
      tunnelService =
        _name: tunnel:
        lib.nameValuePair "netbird-userspace-tunnel-${toString tunnel.localPort}" {
          description = "Forward 127.0.0.1:${toString tunnel.localPort} to ${tunnel.address}:${toString tunnel.port} over NetBird";
          after = [ "netbird-userspace.service" ];
          wants = [ "netbird-userspace.service" ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            ExecStart = "${lib.getExe pkgs.socat} TCP-LISTEN:${toString tunnel.localPort},bind=127.0.0.1,fork,reuseaddr SOCKS5-CONNECT:127.0.0.1:${tunnel.address}:${toString tunnel.port},socksport=${toString socksPort}";

            # The proxy only exists once the client is registered and connected,
            # and a reconnect takes it away, so failing here is expected and the
            # unit retries instead of giving up.
            Restart = "always";
            RestartSec = 5;

            DynamicUser = true;
            NoNewPrivileges = true;
          };
        };

      localPorts = lib.mapAttrsToList (_: tunnel: tunnel.localPort) cfg.tunnels;
    in
    {
      options.services.netbird-userspace = {
        hostname = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "workstation";
          description = ''
            Name this host registers under inside the network, when the machine
            hostname is not the one to use.
          '';
        };

        tunnels = lib.mkOption {
          type = lib.types.attrsOf (
            lib.types.submodule {
              options = {
                localPort = lib.mkOption {
                  type = lib.types.port;
                  description = ''
                    Loopback port this host serves the tunnel on.
                  '';
                };

                address = lib.mkOption {
                  type = lib.types.str;
                  example = "100.69.0.7";
                  description = ''
                    Address of the service, as this client reaches it: either the
                    peer's own NetBird address, or an address inside a subnet
                    route the network advertises through a routing peer.

                    Userspace mode has no resolver inside the tunnel, so this is
                    never a name; `sudo netbird-userspace status --detail` lists
                    the peers, and `sudo netbird-userspace networks list` the
                    network routes with their state.
                  '';
                };

                port = lib.mkOption {
                  type = lib.types.port;
                  description = ''
                    Port the service listens on, on the target.
                  '';
                };
              };
            }
          );
          default = { };
          description = ''
            Services on the NetBird network to serve on loopback, one
            `netbird-userspace-tunnel-<localPort>` service each.

            A tunnel carries TCP only: the client's SOCKS5 proxy offers no UDP.
          '';
        };
      };

      config = {
        assertions = [
          {
            assertion = localPorts == lib.unique localPorts;
            message = "services.netbird-userspace: two tunnels cannot share a localPort.";
          }
          {
            assertion = lib.all (port: port > 1023) localPorts;
            message = "services.netbird-userspace: a tunnel listens unprivileged, so every localPort must be 1024 or above.";
          }
        ];

        environment.systemPackages = [ cli ];

        # Both values live in one document, because a host recipient decrypts the
        # whole of it and only this feature's client reads it. The service user
        # is what needs them: registration runs as that user, and root reads the
        # same files through the CLI.
        sops.secrets."netbird-userspace-management-url" = {
          format = "yaml";
          key = "management_url";
          sopsFile = config.constants.resources.getSecretPath "netbird-userspace.yaml";
          owner = "netbird-userspace";
          group = "netbird-userspace";
          mode = "0400";
          restartUnits = [ "netbird-userspace-register.service" ];
        };

        sops.secrets."netbird-userspace-setup-key" = {
          format = "yaml";
          key = "setup_key";
          sopsFile = config.constants.resources.getSecretPath "netbird-userspace.yaml";
          owner = "netbird-userspace";
          group = "netbird-userspace";
          mode = "0400";
          restartUnits = [ "netbird-userspace-register.service" ];
        };

        users.groups.netbird-userspace = { };

        users.users.netbird-userspace = {
          description = "NetBird userspace client";
          isSystemUser = true;
          group = "netbird-userspace";
        };

        systemd.services = {
          netbird-userspace = {
            description = "NetBird client (userspace)";
            documentation = [ "https://docs.netbird.io/use-cases/cloud/netbird-on-faas" ];
            after = [ "network-online.target" ];
            wants = [ "network-online.target" ];
            wantedBy = [ "multi-user.target" ];

            environment = clientEnv;

            serviceConfig = {
              ExecStart = "${lib.getExe netbird} service run";
              User = "netbird-userspace";
              Group = "netbird-userspace";

              StateDirectory = "netbird-userspace";
              StateDirectoryMode = "0700";
              RuntimeDirectory = "netbird-userspace";
              RuntimeDirectoryMode = "0700";
              # Keys, profile and the daemon socket all land in those
              # directories. The socket itself is created 0666, so the
              # owner-only directory is what keeps every other user on the host
              # out of the daemon; the umask covers the files netbird writes
              # without setting a mode.
              UMask = "0077";

              NoNewPrivileges = true;
              Restart = "always";
              RestartSec = 10;
            };
          };

          # Registration is a CLI step against the running daemon; it stores the
          # account and the endpoint in the state directory, after which the
          # client reconnects on its own. Running it again is harmless.
          netbird-userspace-register = {
            description = "Register the NetBird userspace client with its setup key";
            after = [
              "netbird-userspace.service"
              "sops-install-secrets.service"
            ];
            wants = [ "netbird-userspace.service" ];
            wantedBy = [ "multi-user.target" ];

            environment = clientEnv // {
              NB_SETUP_KEY_FILE = setupKey;
            };

            serviceConfig = {
              Type = "oneshot";
              ExecStart = "${endpointWrapper} ${lib.getExe netbird} up";
              User = "netbird-userspace";
              Group = "netbird-userspace";
              StateDirectory = "netbird-userspace";
              StateDirectoryMode = "0700";
              Restart = "on-failure";
              RestartSec = 30;
              NoNewPrivileges = true;
            };
          };
        }
        // lib.mapAttrs' tunnelService cfg.tunnels;
      };
    };
}
