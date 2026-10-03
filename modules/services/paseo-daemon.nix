{ config, inputs, ... }:
let
  clientPackages = config.pi.packages;
in
{
  flake.modules.aspects.paseo-daemon.imports = [ inputs.self.modules.aspects.pi ];

  flake.modules.nixos.paseo-daemon =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      paseoDaemon = pkgs.selfPackages.paseo-daemon;
      agentPackages = clientPackages pkgs;
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

      environment.systemPackages = [ paseoDaemon ] ++ agentPackages;

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

        path = [
          paseoDaemon
        ]
        ++ agentPackages
        ++ (with pkgs; [
          bashInteractive
          git
          openssh
          nix
          ripgrep
        ]);

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
          # A host that runs the gateway itself talks to it directly; every
          # other host uses the extension's tailnet default, http://box:3425.
          PI_MAGPIE_URL = lib.mkIf (config.systemd.services ? magpie) "http://127.0.0.1:3425";
          # Leave relay enablement in writable config.json: pairing saves it
          # there, and a deployment env override would prevent later changes.
        };

        serviceConfig = {
          Type = "simple";
          User = "paseo";
          Group = "paseo";
          StateDirectory = [
            "paseo"
            "paseo/.pi/agent/extensions"
          ];
          StateDirectoryMode = "0700";
          WorkingDirectory = "/var/lib/paseo";
          # Paseo holds no provider credentials. Its Pi extension reaches every
          # model through the local Magpie gateway, which owns them.
          BindReadOnlyPaths = [
            "${../apps/agents/magpie.ts}:/var/lib/paseo/.pi/agent/extensions/magpie.ts"
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
