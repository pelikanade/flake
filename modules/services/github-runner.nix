{ inputs, ... }:
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

      # Every machine that imports the deploy-target aspect is a target. The
      # runner's own configuration is read locally; the others are independent
      # evaluations. Add the aspect to a machine to include it.
      configurations = inputs.self.nixosConfigurations;
      targetNames = lib.filter (
        name:
        if name == runnerName then
          config.services.deploy-target.enable or false
        else
          configurations.${name}.config.services.deploy-target.enable or false
      ) (builtins.attrNames configurations);

      targetInfo = name: {
        inherit name;
        url = "http://${name}.${config.constants.tailnetDnsName}:8080/deploy";
      };

      targets = map targetInfo targetNames;
      targetList = lib.concatStringsSep " " (map (target: target.name) targets);
      targetUrls = lib.concatStringsSep " " (map (target: ''[${target.name}]="${target.url}"'') targets);
      localName = config.networking.hostName;

      trigger = pkgs.writeShellApplication {
        name = "nixos-deploy-trigger";
        runtimeInputs = [
          config.nix.package
          pkgs.coreutils
          pkgs.curl
        ];
        text = ''
          set -euo pipefail

          token=$(cat /run/secrets/deploy_trigger_token)
          read -r -a targets <<< "${targetList}"
          local_machine="${localName}"
          declare -A paths
          declare -A urls=( ${targetUrls} )

          for target in "''${targets[@]}"; do
            paths[$target]=$(nix build --no-link --print-out-paths ".#nixosConfigurations.$target.config.system.build.toplevel")
          done

          post() {
            local target="$1"
            curl --fail --silent --show-error --max-time 7200 \
              --request POST \
              --header "Authorization: Bearer $token" \
              --data-binary "''${paths[$target]}" \
              "''${urls[$target]}"
          }

          for target in "''${targets[@]}"; do
            if [ "$target" = "$local_machine" ]; then
              continue
            fi
            post "$target"
          done

          # The local switch can restart this runner; the target's transient
          # deploy unit keeps running even if the request is cut off.
          case " ''${targets[*]} " in
            *" $local_machine "*) post "$local_machine" || true ;;
          esac
        '';
      };
    in
    {
      assertions = [
        {
          assertion = targets != [ ];
          message = "github-runner: no machine imports deploy-target";
        }
      ];

      users.groups.${deployUser} = { };

      users.users.${deployUser} = {
        isSystemUser = true;
        group = deployUser;
        extraGroups = [ "deploy" ];
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
        serviceOverrides = {
          SupplementaryGroups = [ "deploy" ];
        };
      };

      environment.systemPackages = [ trigger ];
    };
}
