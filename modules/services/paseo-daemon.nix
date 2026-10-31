{ inputs, ... }:
{
  flake.modules.aspects.paseo-daemon.imports = [
    inputs.self.modules.aspects.omp
    inputs.self.modules.aspects.podman
  ];

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
      virtualisation.podman.runtimeApis.paseo = { };

      users.groups.paseo = { };
      users.users.paseo = {
        isSystemUser = true;
        group = "paseo";
        # Agents run as this account and drive `podman` or `docker`, which address
        # the API socket published below rather than a runtime of their own: the
        # daemon's sandbox refuses the setuid helper that an in-process rootless
        # Podman needs. A subordinate ID range and a lingering user manager —
        # which owns `/run/user/<uid>`, where that runtime keeps its cgroups —
        # are what the API service needs.
        autoSubUidGidRange = true;
        linger = true;
        home = "/var/lib/paseo";
        createHome = true;
        homeMode = "0700";
        shell = pkgs.bashInteractive;

        # sshd runs a forced command through the account's login shell —
        # `execve($shell, "-c", $command)` — so the account keeps
        # `pkgs.bashInteractive` rather than a nologin shell, which would refuse
        # the pull.
        openssh.authorizedKeys.keys = [
          ''restrict,command="${pkgs.rrsync}/bin/rrsync -ro ${config.users.users.paseo.home}/.omp" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEHBB0wxvOIXXPPIrrCCp1D/WsIZshxOLnlw1N+JY+e5 grokbot-box omp-ro pull''
        ];
      };

      environment.systemPackages = [
        paseoDaemon
        pkgs.devenv
      ];

      sops.secrets.paseo-password = {
        format = "yaml";
        key = "password";
        sopsFile = config.constants.resources.getSecretPath "paseo.yaml";
      };

      sops.templates.paseo-daemon-env = {
        content = "PASEO_PASSWORD=${config.sops.placeholder.paseo-password}\n";
        restartUnits = [ "paseo-daemon.service" ];
      };

      sops.templates.paseo-omp-magpie = {
        content = builtins.toJSON {
          endpoint = config.sops.placeholder.omp-magpie-endpoint;
          api_key = config.sops.placeholder.omp-magpie-api-key;
        };
        path = "${config.users.users.paseo.home}/.omp/agent/magpie.yaml";
        owner = "paseo";
        group = "paseo";
        mode = "0400";
        restartUnits = [ "paseo-daemon.service" ];
      };

      systemd.tmpfiles.rules = [
        "d ${config.users.users.paseo.home}/.omp 0700 paseo paseo -"
        "d ${config.users.users.paseo.home}/.omp/agent 0700 paseo paseo -"
      ];

      systemd.services.paseo-daemon = {
        description = "Paseo host for coding agents and terminals";
        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];

        # systemd's path option replaces the unit's PATH rather than extending it,
        # so point it at the system profile instead of listing packages again.
        path = [ config.system.path ];

        environment = {
          HOME = "/var/lib/paseo";
          PASEO_HOME = "/var/lib/paseo/.paseo";
          PI_CONFIG_FILES = toString (
            (pkgs.formats.yaml { }).generate "omp-magpie-config.yml" {
              extensions = [ "${pkgs.selfPackages.omp-magpie}/share/omp/extensions/magpie" ];
            }
          );
          PASEO_LISTEN = lib.mkDefault "0.0.0.0:6767";
          PASEO_NODE_ENV = "production";
          SHELL = lib.getExe pkgs.bashInteractive;
          CONTAINER_HOST = "unix://${config.virtualisation.podman.runtimeApis.paseo.socketPath}";
          DOCKER_HOST = "unix://${config.virtualisation.podman.runtimeApis.paseo.socketPath}";
        }
        // lib.optionalAttrs ((config.services.tailscale-ingress.services or { }) != { }) {
          # The daemon answers a Host header it was not told about with 403
          # "Invalid Host header" — its defaults allow localhost and plain IPs
          # only — and a client reports that as a transport that closed. Its
          # Tailscale Service is `<name>.<tailnetDnsName>`, so the whole tailnet
          # suffix covers it, along with the node's own MagicDNS name.
          PASEO_HOSTNAMES = ".${config.constants.tailnetDnsName}";
        };

        serviceConfig = {
          Type = "simple";
          User = "paseo";
          Group = "paseo";
          EnvironmentFile = config.sops.templates.paseo-daemon-env.path;
          StateDirectory = [
            "paseo"
            "paseo/.omp/agent"
          ];
          StateDirectoryMode = "0700";
          WorkingDirectory = "/var/lib/paseo";
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

          MemoryHigh = "20G";
          MemoryMax = "24G";

          ManagedOOMMemoryPressure = "kill";
          ManagedOOMMemoryPressureLimit = "80%";
        };
      };
    };
}
