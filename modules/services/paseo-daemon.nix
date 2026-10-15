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
      # The account can run containers, so the host publishes its runtime's API on
      # a fixed socket. The socket belongs to the account itself until a client
      # claims it with `virtualisation.podman.runtimeApis.paseo.client`.
      virtualisation.podman.runtimeApis.paseo = { };

      users.groups.paseo = { };
      users.users.paseo = {
        isSystemUser = true;
        group = "paseo";
        # Agents run as this account and may call `podman` or `docker`. A
        # subordinate ID range and a lingering user manager — which owns
        # `/run/user/<uid>` and the rootless Podman socket inside it — are what
        # let them run containers without root. No group grants container
        # control, and the daemon has no container runtime to order against.
        autoSubUidGidRange = true;
        linger = true;
        home = "/var/lib/paseo";
        createHome = true;
        homeMode = "0700";
        shell = pkgs.bashInteractive;

        # The Grok Bot box pulls omp session logs from `.omp` once a night, and
        # this key is its only way in. sshd runs a forced command through the
        # account's login shell — `execve($shell, "-c", $command)` — so the
        # account keeps `pkgs.bashInteractive` rather than a nologin shell,
        # which would refuse the pull. Nothing interactive follows from that:
        # the password is locked, password and keyboard-interactive
        # authentication are off, and this is the account's only key.
        #
        # `restrict` denies port, agent and X11 forwarding, PTY allocation and
        # the user rc file, and the forced command replaces whatever the client
        # asks for, so no shell and no sftp session is reachable either way.
        # `rrsync -ro` accepts `--sender` requests only, so the peer cannot
        # write, and the path bounds it to this one directory. `rrsync` is its
        # own package: `pkgs.rsync` installs `rsync` and `rsync-ssl` alone. That
        # directory also holds `.omp/agent/magpie.yaml`, the Magpie credential,
        # which the puller therefore reads as well.
        openssh.authorizedKeys.keys = [
          ''restrict,command="${pkgs.rrsync}/bin/rrsync -ro ${config.users.users.paseo.home}/.omp" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEHBB0wxvOIXXPPIrrCCp1D/WsIZshxOLnlw1N+JY+e5 grokbot-box omp-ro pull''
        ];
      };

      # The unit takes the whole system profile as its PATH, so the agents it
      # spawns see everything installed here, omp included. Agents run `devenv`
      # for project dev shells; the workstation role installs it only for desktop
      # users, and this account has no Home Manager.
      environment.systemPackages = [
        paseoDaemon
        pkgs.devenv
      ];

      # The daemon hashes PASEO_PASSWORD at startup, and that hash takes precedence
      # over any password stored in its config.json. The value lives in its own
      # document, read only by this host.
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
          # Tailnet peers reach the daemon on this host's tailnet address, which
          # sing-box's userspace endpoint delivers to loopback, so it binds every
          # interface and the password from the sops environment file below is
          # what bounds it.
          PASEO_LISTEN = lib.mkDefault "0.0.0.0:6767";
          PASEO_NODE_ENV = "production";
          SHELL = lib.getExe pkgs.bashInteractive;
          # Paseo ships its built-in omp provider disabled, and it rewrites this
          # daemon's config.json for pairing and relay state. Enabling the provider
          # is a manual change there, outside this repository. Leave relay
          # enablement there too: a deployment env override would prevent later
          # changes.
        }
        // lib.optionalAttrs ((config.services.ingress.domain or null) != null) {
          # The daemon answers a Host header it was not told about with 403
          # "Invalid Host header" — its defaults allow localhost and plain IPs
          # only — and a client reports that as a transport that closed. A client
          # that dials the ingress's name, or the MagicDNS name it had before the
          # ingress existed, must find it here.
          PASEO_HOSTNAMES = ".${config.services.ingress.domain},.${config.constants.tailnetDnsName}";
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
        };
      };
    };
}
