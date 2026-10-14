{
  flake.modules.nixos.netbird-user =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.services.netbird-user;

      # A userspace (netstack) client: WireGuard runs on a Go TCP/IP stack
      # instead of a TUN device, so an unprivileged service user runs it, and it
      # touches no interface, route, resolver entry or firewall rule of the host.
      # Its only opening is a SOCKS5 proxy on loopback, which is what the
      # tunnels below dial; see docs/netbird-user.md. The workplace client from
      # apps/netbird-desktop.nix is a different peer and stays as it is.
      netbird = pkgs.unstable.netbird;

      # None of these are options: nothing else on the host depends on them, and
      # the tunnels are the only consumer of the proxy.
      stateDir = "/var/lib/netbird-user";
      socksPort = 1080;
      daemonAddr = "unix:///run/netbird-user/sock";

      # One environment for the daemon, the registration unit and the CLI, so
      # all three address the same client and the same state.
      clientEnv = {
        NB_USE_NETSTACK_MODE = "true";
        NB_SOCKS5_LISTENER_PORT = toString socksPort;
        NB_STATE_DIR = stateDir;
        NB_DAEMON_ADDR = daemonAddr;
        # An unprivileged daemon cannot create /var/log/netbird and refuses to
        # start without a writable log, so it logs to the journal instead.
        NB_LOG_FILE = "console";
      }
      // lib.optionalAttrs (cfg.managementUrl != null) { NB_MANAGEMENT_URL = cfg.managementUrl; }
      // lib.optionalAttrs (cfg.hostname != null) { NB_HOSTNAME = cfg.hostname; };

      envLines = lib.concatLines (
        lib.mapAttrsToList (name: value: "export ${name}=${lib.escapeShellArg value}") clientEnv
      );

      # The CLI carries the same environment, so `netbird-user` talks to this
      # client rather than to the workplace daemon's socket.
      cli = pkgs.writeShellScriptBin "netbird-user" ''
        ${envLines}
        exec ${lib.getExe netbird} "$@"
      '';

      # socat terminates the loopback connection and dials the peer through the
      # client's SOCKS5 proxy, which is unauthenticated and loopback-only:
      # neither listener is reachable from the LAN.
      tunnelService =
        _name: tunnel:
        lib.nameValuePair "netbird-user-tunnel-${toString tunnel.localPort}" {
          description = "Forward 127.0.0.1:${toString tunnel.localPort} to ${tunnel.address}:${toString tunnel.port} over NetBird";
          after = [ "netbird-user.service" ];
          wants = [ "netbird-user.service" ];
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
      options.services.netbird-user = {
        managementUrl = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "https://api.example.com:443";
          description = ''
            Management server to join. A self-hosted deployment needs it; the
            default is NetBird's own.
          '';
        };

        hostname = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "workstation";
          description = ''
            Name this host registers under inside the network, when the machine
            hostname is not the one to use.
          '';
        };

        setupKeyFile = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          example = "/run/secrets/netbird-setup-key";
          description = ''
            File holding a setup key, for a network that issues them.

            With one, the host registers unattended at every boot. Without one,
            joining the network is a manual step: `sudo netbird-user up` prints
            an activation URL for the network's SSO login.

            The file has to be readable by the `netbird-user` service user,
            which is the user that runs both the registration and the client.
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
                    never a name; `sudo netbird-user status --detail` lists the
                    peers, and `sudo netbird-user networks list` the network
                    routes with their state.
                  '';
                };

                port = lib.mkOption {
                  type = lib.types.port;
                  description = ''
                    Port the service listens on, on the peer.
                  '';
                };
              };
            }
          );
          default = { };
          description = ''
            Services on the NetBird network to serve on loopback, one
            `netbird-user-tunnel-<localPort>` service each.

            A tunnel carries TCP only: the client's SOCKS5 proxy offers no UDP.
          '';
        };
      };

      config = {
        assertions = [
          {
            assertion = localPorts == lib.unique localPorts;
            message = "services.netbird-user: two tunnels cannot share a localPort.";
          }
          {
            assertion = lib.all (port: port > 1023) localPorts;
            message = "services.netbird-user: a tunnel listens unprivileged, so every localPort must be 1024 or above.";
          }
        ];

        environment.systemPackages = [ cli ];

        users.groups.netbird-user = { };

        users.users.netbird-user = {
          description = "NetBird userspace client";
          isSystemUser = true;
          group = "netbird-user";
        };

        systemd.services = {
          netbird-user = {
            description = "NetBird client (userspace)";
            documentation = [ "https://docs.netbird.io/use-cases/cloud/netbird-on-faas" ];
            after = [ "network-online.target" ];
            wants = [ "network-online.target" ];
            wantedBy = [ "multi-user.target" ];

            environment = clientEnv;

            serviceConfig = {
              ExecStart = "${lib.getExe netbird} service run";
              User = "netbird-user";
              Group = "netbird-user";

              StateDirectory = "netbird-user";
              StateDirectoryMode = "0700";
              RuntimeDirectory = "netbird-user";
              RuntimeDirectoryMode = "0700";
              # Keys, config and the daemon socket all land in those
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
          # account in the state directory, after which the client reconnects on
          # its own. Running it again is harmless.
          netbird-user-register = lib.mkIf (cfg.setupKeyFile != null) {
            description = "Register the NetBird userspace client with a setup key";
            after = [
              "netbird-user.service"
              "sops-install-secrets.service"
            ];
            wants = [ "netbird-user.service" ];
            wantedBy = [ "multi-user.target" ];

            environment = clientEnv // {
              NB_SETUP_KEY_FILE = cfg.setupKeyFile;
            };

            serviceConfig = {
              Type = "oneshot";
              ExecStart = "${lib.getExe netbird} up";
              User = "netbird-user";
              Group = "netbird-user";
              StateDirectory = "netbird-user";
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
