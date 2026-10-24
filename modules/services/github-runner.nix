{
  config,
  ...
}:
let
  inherit (config) machines;
in
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

      # The `auto-deployable` machine tag marks a host as a deployment target.
      # Derive the list from the machine definitions so the polkit rule and the
      # deploy script do not repeat names.
      deployTargets = lib.filter (name: lib.elem "auto-deployable" machines.${name}.tags) (
        builtins.attrNames machines
      );

      targetInfo = name: {
        inherit name;
        local = name == config.networking.hostName;
        fqdn = config.constants.getTailnetFqdn name;
      };

      targets = map targetInfo deployTargets;
      targetList = lib.concatStringsSep " " (map (target: target.name) targets);
      targetPattern = lib.concatStringsSep " | " (map (target: target.name) targets);

      targetCase = lib.concatStringsSep "\n" (
        map (
          target:
          if target.local then
            ''
              ${target.name})
                exec /run/current-system/sw/bin/nixos-rebuild switch --flake "$src#${target.name}" -L
                ;;
            ''
          else
            ''
              ${target.name})
                exec /run/current-system/sw/bin/nixos-rebuild switch \
                  --flake "$src#${target.name}" \
                  --target-host "root@${target.fqdn}" \
                  -L
                ;;
            ''
        ) targets
      );

      polkitUnits = lib.concatMapStringsSep " ||\n" (
        target: ''action.lookup("unit") == "nixos-deploy@${target.name}.service"''
      ) targets;

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
            ${targetPattern}) ;;
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
          ${targetCase}
          esac
        '';
      };

      # Run as the runner user before the root units: it is the build gate and
      # warms the store for every target.
      deployBuild = pkgs.writeShellApplication {
        name = "nixos-deploy-build";
        runtimeInputs = [
          config.nix.package
          pkgs.coreutils
          pkgs.git
        ];
        text = ''
          set -euo pipefail

          for machine in ${targetList}; do
            nix build --no-link ".#nixosConfigurations.$machine.config.system.build.toplevel"
          done
        '';
      };

      # The runner may start any deploy target, or all of them in the safe
      # order: every remote target first, the runner's own host last.
      deployRequest = pkgs.writeShellApplication {
        name = "nixos-deploy-request";
        runtimeInputs = [ pkgs.systemd ];
        text = ''
          set -euo pipefail

          machine="''${1:?machine required}"
          case "$machine" in
            all | ${targetPattern}) ;;
            *)
              echo "unsupported machine: $machine" >&2
              exit 2
              ;;
          esac

          targets="${targetList}"
          local_machine="${config.networking.hostName}"

          if [ "$machine" = all ]; then
            for target in $targets; do
              if [ "$target" = "$local_machine" ]; then
                continue
              fi
              systemctl start --wait --no-ask-password "nixos-deploy@$target.service"
            done
            case " $targets " in
              *" $local_machine "*) systemctl start --wait --no-ask-password "nixos-deploy@$local_machine.service" ;;
            esac
          else
            systemctl start --wait --no-ask-password "nixos-deploy@$machine.service"
          fi
        '';
      };
    in
    {
      assertions = [
        {
          assertion = targets != [ ];
          message = "github-runner: tag at least one machine auto-deployable";
        }
      ];

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

      environment.systemPackages = [
        deployBuild
        deployRequest
      ];

      # The runner never gains privileges. Polkit lets it ask PID 1 to start the
      # derived deployment units; the runner keeps NoNewPrivileges=true.
      security.polkit = {
        enable = true;
        extraConfig = ''
          polkit.addRule(function(action, subject) {
            if (action.id == "org.freedesktop.systemd1.manage-units" &&
                subject.user == "${deployUser}" &&
                action.lookup("verb") == "start" &&
                (${polkitUnits})) {
              return polkit.Result.YES;
            }
          });
        '';
      };
    };
}
