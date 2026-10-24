{
  flake.modules.nixos.github-runner =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      runnerName = "neko-sphere";
      deployUser = "github-runner";

      # The deploy itself runs in the root unit below, outside the runner's
      # sandbox. It clones main from GitHub rather than trusting the runner's
      # working tree, so a job can trigger a deployment of main but cannot inject
      # a flake of its own.
      deployScript = pkgs.writeShellApplication {
        name = "nixos-deploy";
        runtimeInputs = [
          config.nix.package
          pkgs.coreutils
          pkgs.git
          pkgs.openssh
        ];
        text = ''
          set -euo pipefail

          machine="''${1:?machine required}"
          case "$machine" in
            neko-sphere | edge) ;;
            *)
              echo "unsupported machine: $machine" >&2
              exit 2
              ;;
          esac

          root=/var/lib/nixos-deploy
          src="$root/$machine"
          install -d -m 0700 "$root"
          rm -rf "$src"
          git clone --depth 1 --branch main \
            https://github.com/pelikanade/flake.git "$src"

          # Tailscale SSH authenticates the peer through the tailnet. The host
          # key is accepted on first use and kept beside the checkout; removing
          # the store after a reinstall lets the next deploy learn the new key.
          export HOME=/root
          export NIX_SSHOPTS="-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$root/known_hosts"

          case "$machine" in
            neko-sphere)
              exec /run/current-system/sw/bin/nixos-rebuild switch \
                --flake "$src#neko-sphere" -L
              ;;
            edge)
              exec /run/current-system/sw/bin/nixos-rebuild switch \
                --flake "$src#edge" \
                --target-host "root@${config.constants.getTailnetFqdn "edge"}" \
                -L
              ;;
          esac
        '';
      };

      # The runner is allowed to start only these two deployments. The wait makes
      # the job fail when the unit fails; the unit itself keeps running if the
      # runner is restarted by the neko-sphere switch.
      deployRequest = pkgs.writeShellApplication {
        name = "nixos-deploy-request";
        runtimeInputs = [ pkgs.systemd ];
        text = ''
          set -euo pipefail

          machine="''${1:?machine required}"
          case "$machine" in
            neko-sphere | edge) ;;
            *)
              echo "unsupported machine: $machine" >&2
              exit 2
              ;;
          esac

          status=0
          systemctl start --wait "nixos-deploy@$machine.service" || status=$?
          journalctl -u "nixos-deploy@$machine.service" --no-pager -n 200 || true
          exit "$status"
        '';
      };
    in
    {
      users.groups.${deployUser} = { };

      users.users.${deployUser} = {
        isSystemUser = true;
        group = deployUser;
        description = "GitHub Actions runner and deployment requester";
      };

      sops.secrets.github_runner_token = {
        sopsFile = ../secrets/github-runner.yaml;
        owner = deployUser;
        group = deployUser;
        mode = "0400";
      };

      services.github-runners.${runnerName} = {
        enable = true;
        url = "https://github.com/pelikanade/flake";
        name = runnerName;
        tokenFile = config.sops.secrets.github_runner_token.path;
        tokenType = "access";
        ephemeral = true;
        replace = true;
        extraLabels = [ runnerName ];
        user = deployUser;
        group = deployUser;

        # `sudo` must change credentials and talk to PID 1; the filesystem and
        # network sandbox stays as the module sets it. The switch itself runs in
        # the unsandboxed root unit, so no job builds or activates as root.
        serviceOverrides = {
          NoNewPrivileges = false;
          PrivateUsers = false;
          ProtectSystem = "full";
          CapabilityBoundingSet = lib.mkForce [ ];
          AmbientCapabilities = lib.mkForce [ ];
          SystemCallFilter = lib.mkForce [ ];
        };
      };

      systemd.services."nixos-deploy@" = {
        description = "Deploy NixOS configuration %i from GitHub main";
        wants = [ "network-online.target" ];
        after = [
          "network-online.target"
          "tailscaled.service"
        ];
        serviceConfig = {
          Type = "oneshot";
          TimeoutStartSec = "2h";
          ExecStart = "${deployScript}/bin/nixos-deploy %i";
          Environment = [
            "HOME=/root"
            "PATH=/run/current-system/sw/bin:${
              lib.makeBinPath [
                config.nix.package
                pkgs.coreutils
                pkgs.git
                pkgs.openssh
              ]
            }"
          ];
        };
      };

      environment.systemPackages = [ deployRequest ];

      security.sudo.extraRules = [
        {
          users = [ deployUser ];
          commands = [
            {
              command = "/run/current-system/sw/bin/nixos-deploy-request";
              options = [ "NOPASSWD" ];
            }
          ];
        }
      ];
    };
}
