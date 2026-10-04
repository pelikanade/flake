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

      # The daemon has no interactive login, so it reaches the key-based
      # providers only; Codex and Cursor stay with the desktops whose users run
      # `omp /login`. Each key resolves when a request needs it.
      modelsYaml = pkgs.writeText "paseo-omp-models.yml" ''
        providers:
          deepseek:
            apiKey: "!cat /run/secrets/paseo-omp-deepseek-api-key"
          openrouter:
            apiKey: "!cat /run/secrets/paseo-omp-openrouter-api-key"
      '';
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

      # The daemon's omp is the only consumer of these keys, and it is not the
      # desktop user's: decrypt a copy owned by the paseo service user. A key
      # change restarts the unit because omp caches `!` command output for the
      # process lifetime.
      sops.secrets = {
        paseo-omp-deepseek-api-key = {
          format = "yaml";
          key = "deepseek_api_key";
          sopsFile = config.constants.resources.getSecretPath "omp-providers.yaml";
          owner = "paseo";
          group = "paseo";
          mode = "0400";
          restartUnits = [ "paseo-daemon.service" ];
        };
        paseo-omp-openrouter-api-key = {
          format = "yaml";
          key = "openrouter_api_key";
          sopsFile = config.constants.resources.getSecretPath "omp-providers.yaml";
          owner = "paseo";
          group = "paseo";
          mode = "0400";
          restartUnits = [ "paseo-daemon.service" ];
        };
      };

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
            "paseo/.omp/agent"
          ];
          StateDirectoryMode = "0700";
          WorkingDirectory = "/var/lib/paseo";
          # Paseo holds no OAuth logins. Its omp declares the key-based providers
          # in this read-only models.yml and reads the keys by path from sops.
          BindReadOnlyPaths = [
            "${modelsYaml}:/var/lib/paseo/.omp/agent/models.yml"
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
