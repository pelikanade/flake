{ inputs, ... }:
{
  # The Paseo account hosts agents that change this machine's configuration, but
  # its daemon keeps `NoNewPrivileges=true`, which disables every setuid route
  # out of that sandbox — `sudo`, `pkexec`, and a setuid helper of our own alike.
  # A deployment request therefore has to arrive at a service that already runs
  # as root, and this socket with its per-connection unit is that service.
  # Compose this aspect with `paseo-daemon`, which declares the account it serves.
  # See docs/paseo-deploy.md.
  flake.modules.nixos.paseo-deploy =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      socketPath = "/run/paseo-deploy.sock";

      flake = config.services.paseo-deploy.flake;

      # The broker answers one connection with one deployment. It runs as root;
      # the socket's owner is the whole boundary, and the caller has no say in
      # what gets deployed — the flake above does.
      broker = pkgs.selfPackages.paseo-deploy-broker;
    in
    {
      options.services.paseo-deploy.flake = lib.mkOption {
        type = lib.types.str;
        example = "github:pelikanade/flake";
        description = ''
          The flake this machine deploys. Every request fetches its latest
          revision — the current tip of its default branch — and switches to that,
          so the machine follows the published repository and never a local
          checkout.
        '';
      };

      config = {
        # The account runs the client package, whose interpreter is its own store
        # path; the daemon's PATH is the system profile.
        environment.systemPackages = [ pkgs.selfPackages.paseo-deploy ];

        systemd.sockets.paseo-deploy = {
          description = "Deployment requests from the Paseo account";
          wantedBy = [ "sockets.target" ];
          listenStreams = [ socketPath ];
          socketConfig = {
            # Only the account that makes these requests may connect to it.
            SocketMode = "0600";
            SocketUser = "paseo";
            SocketGroup = "paseo";
            # One instance per connection, which is what hands a request and its
            # answer to the service below.
            Accept = "yes";
          };
        };

        systemd.services."paseo-deploy@" = {
          description = "Deploy the latest revision of this machine's flake";
          # One instance per connection: release each one as it ends instead of
          # accumulating it, which is what systemd recommends for `Accept=yes`.
          unitConfig.CollectMode = "inactive-or-failed";

          # The broker's interpreter is the one in its own store path; `path` gives
          # it the activated system's `nixos-rebuild` and `systemd-run`, the entry
          # points the documented manual route uses. systemd's path option replaces
          # the unit's PATH rather than extending it, so point it at the system
          # profile instead of listing packages again.
          path = [ config.system.path ];

          # The caller sends nothing and cannot choose what is deployed.
          environment.PASEO_DEPLOY_FLAKE = flake;

          serviceConfig = {
            # `Accept=yes` gives each instance the connection on the standard
            # file descriptors, so the service needs no listener of its own.
            StandardInput = "socket";
            StandardOutput = "socket";
            StandardError = "socket";
            ExecStart = lib.getExe' broker "paseo-deploy-broker";
          };
        };
      };
    };
}
