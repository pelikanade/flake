{ inputs, ... }:
{
  flake.modules.aspects.paseo-daemon.imports = [ inputs.self.modules.aspects.omp ];

  flake.modules.nixos.paseo-daemon =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      paseoDaemon = pkgs.selfPackages.paseo-daemon;
    in
    {
      users.groups.paseo = { };
      users.users.paseo = {
        isSystemUser = true;
        group = "paseo";
        home = "/var/lib/paseo";
        createHome = true;
        homeMode = "0700";
        shell = pkgs.bashInteractive;
      };

      # The unit takes the whole system profile as its PATH, so the agents it
      # spawns see everything the omp aspect installs there, omp included.
      environment.systemPackages = [ paseoDaemon ];

      # Reachable on the tailnet and on loopback only. `tailnet0` is the system
      # interface of the sing-box Tailscale endpoint.
      networking.firewall.interfaces.tailnet0.allowedTCPPorts = [ 6767 ];

      systemd.services.paseo-daemon = {
        description = "Paseo host for coding agents and terminals";
        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" ];
        after = [
          "network-online.target"
        ];

        # systemd's path option replaces the unit's PATH rather than extending it,
        # so point it at the system profile instead of listing packages again.
        path = [ config.system.path ];

        environment = {
          HOME = "/var/lib/paseo";
          PASEO_HOME = "/var/lib/paseo/.paseo";
          # Tailnet peers reach the daemon on this host's tailnet address, so it
          # binds every interface; this module admits 6767 on tailnet0 only, and
          # loopback keeps working. Configure its password before relying on
          # that: the tailnet is the other boundary.
          PASEO_LISTEN = lib.mkDefault "0.0.0.0:6767";
          PASEO_NODE_ENV = "production";
          SHELL = lib.getExe pkgs.bashInteractive;
          # A host that runs the gateway itself talks to it over loopback; every
          # other host addresses it by its fully qualified MagicDNS name, because
          # the resolver does not expand a bare peer name.
          PI_MAGPIE_URL =
            if config.systemd.services ? magpie then
              "http://127.0.0.1:3425"
            else
              "http://${config.constants.getTailnetFqdn "box"}:3425";
          # Paseo ships its built-in omp provider disabled, and it rewrites this
          # daemon's config.json for pairing and relay state. Enabling the provider
          # is a manual change there, outside this repository. Leave relay
          # enablement there too: a deployment env override would prevent later
          # changes.
        };

        serviceConfig = {
          Type = "simple";
          User = "paseo";
          Group = "paseo";
          StateDirectory = [
            "paseo"
            "paseo/.omp/agent/extensions"
          ];
          StateDirectoryMode = "0700";
          WorkingDirectory = "/var/lib/paseo";
          # Paseo holds no provider credentials. Its omp extension reaches every
          # model through the local Magpie gateway, which owns them.
          BindReadOnlyPaths = [
            "${../apps/agents/magpie.ts}:/var/lib/paseo/.omp/agent/extensions/magpie.ts"
          ];
          ExecStart = "${lib.getExe paseoDaemon} daemon run";
          Restart = "on-failure";
          RestartSec = 5;
          KillMode = "control-group";
          TimeoutStopSec = 30;
          UMask = "0077";
          NoNewPrivileges = true;
          ProtectSystem = "full";
          ProtectHome = true;
          PrivateTmp = true;
        };
      };
    };
}
