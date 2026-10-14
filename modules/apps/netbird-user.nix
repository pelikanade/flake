{
  flake.modules.homeManager.netbird-user =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.services.netbird-user;

      # The workplace client from apps/netbird-desktop.nix is the kernel one and
      # stays as it is: this is a second, unprivileged client for a network the
      # user only reaches through a forwarded port. In userspace mode (netstack)
      # WireGuard runs on a Go TCP/IP stack instead of a TUN device, so the
      # client needs neither root nor a firewall rule, and it neither touches
      # the resolver, the routing table nor the SSH configuration. What it does
      # provide is a SOCKS5 proxy on loopback, which is the only way into the
      # tunnel and what the forwarders below dial.
      netbird = pkgs.unstable.netbird;

      # Profile, WireGuard and SSH keys, and the daemon socket. The directory is
      # the user's own, so an unprivileged client owns it; systemd's
      # StateDirectory creates it 0700 before the daemon starts, and netbird
      # creates it itself if it is missing.
      stateDir = "${config.xdg.stateHome}/netbird-user";

      # Keeping the socket in the state directory is what lets the daemon and
      # the CLI name the same path from the build: a runtime directory would be
      # a second location to keep in step. Netbird creates the socket 0666, so
      # what keeps other users off it is the 0700 directory around it.
      daemonAddr = "unix://${stateDir}/sock";

      # Same environment for the CLI, so `netbird-user` reaches this client
      # rather than the socket the workplace daemon listens on.
      cli = pkgs.writeShellScriptBin "netbird-user" ''
        export NB_STATE_DIR=${lib.escapeShellArg stateDir}
        export NB_DAEMON_ADDR=${lib.escapeShellArg daemonAddr}
        export NB_LOG_FILE=console
        exec ${lib.getExe netbird} "$@"
      '';

      daemon = {
        Unit = {
          Description = "NetBird client (userspace)";
          Documentation = [ "https://docs.netbird.io/use-cases/cloud/netbird-on-faas" ];
          After = [ "network.target" ];
        };

        Service = {
          ExecStart = "${lib.getExe netbird} service run";

          Environment = [
            # Netstack mode. Besides the userspace datapath it also means the
            # client manages no DNS and no routes, and the daemon needs no
            # capabilities to do its work.
            "NB_USE_NETSTACK_MODE=true"
            "NB_SOCKS5_LISTENER_PORT=${toString cfg.socksPort}"
            "NB_STATE_DIR=${stateDir}"
            "NB_DAEMON_ADDR=${daemonAddr}"
            # As a user the daemon cannot create /var/log/netbird and refuses to
            # start without a writable log, so it logs to the journal.
            "NB_LOG_FILE=console"
          ];

          StateDirectory = "netbird-user";
          StateDirectoryMode = "0700";
          # Keys, config and the daemon socket all land in that directory. The
          # socket itself is created 0666, so the owner-only directory is what
          # keeps every other user on the host out of the daemon; the umask
          # covers the files netbird writes without setting a mode itself.
          UMask = "0077";
          NoNewPrivileges = true;

          Restart = "always";
          RestartSec = 10;
        };

        Install.WantedBy = [ "default.target" ];
      };

      # One service per forward, named after the port it answers on so that two
      # entries cannot both claim one: the second would be the same unit name.
      forward =
        _name: fwd:
        lib.nameValuePair "netbird-user-forward-${toString fwd.localPort}" {
          Unit = {
            Description = "Forward 127.0.0.1:${toString fwd.localPort} to ${fwd.peer}:${toString fwd.peerPort} over NetBird";
            After = [ "netbird-user.service" ];
            Wants = [ "netbird-user.service" ];
          };

          Service = {
            # socat terminates the loopback connection and dials the peer
            # through the client's SOCKS5 proxy, which is unauthenticated and
            # loopback-only: neither listener here is reachable from the LAN.
            ExecStart = "${lib.getExe pkgs.socat} TCP-LISTEN:${toString fwd.localPort},bind=127.0.0.1,fork,reuseaddr SOCKS5-CONNECT:127.0.0.1:${fwd.peer}:${toString fwd.peerPort},socksport=${toString cfg.socksPort}";

            # The proxy only exists once the client is logged in and connected,
            # and a reconnect takes it away, so failing here is expected and the
            # unit retries instead of giving up.
            Restart = "always";
            RestartSec = 5;
            NoNewPrivileges = true;
          };

          Install.WantedBy = [ "default.target" ];
        };
    in
    {
      options.services.netbird-user = {
        socksPort = lib.mkOption {
          type = lib.types.port;
          default = 1080;
          description = ''
            Port the client's SOCKS5 proxy listens on, on loopback.

            Every program running as this user reaches the NetBird network
            through it, and it asks for no credentials, so it is not exposed
            beyond 127.0.0.1.
          '';
        };

        forwards = lib.mkOption {
          type = lib.types.attrsOf (
            lib.types.submodule {
              options = {
                localPort = lib.mkOption {
                  type = lib.types.port;
                  description = ''
                    Loopback port this host answers on.
                  '';
                };

                peer = lib.mkOption {
                  type = lib.types.str;
                  example = "100.69.0.7";
                  description = ''
                    Address of the peer that runs the service.

                    Userspace mode has no resolver inside the tunnel, so this is
                    the peer's NetBird address — `netbird-user status --detail`
                    lists the peers and their addresses — and never a name.
                  '';
                };

                peerPort = lib.mkOption {
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
            Services on the NetBird network to serve on loopback.

            The attribute name only labels the entry; each one becomes a
            `netbird-user-forward-<localPort>` user service.
          '';
        };
      };

      config = {
        home.packages = [ cli ];

        systemd.user.services = {
          netbird-user = daemon;
        }
        // lib.mapAttrs' forward cfg.forwards;
      };
    };
}
