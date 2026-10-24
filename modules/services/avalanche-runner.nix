{
  flake.modules.nixos.avalanche-runner =
    { config, pkgs, ... }:
    let
      runnerName = "neko-sphere";
      runnerUser = "github-runner";
      runnerService = "github-runner-${runnerName}";
    in
    {
      environment.systemPackages = [ pkgs.selfPackages.avalanche ];

      users.groups.${runnerUser} = { };
      users.groups.avalanche = { };

      users.users.${runnerUser} = {
        isSystemUser = true;
        group = runnerUser;
        description = "GitHub Actions runner";
      };

      # This runner exists to deploy the avalanche targets, so it owns its
      # registration PAT from the avalanche document and may read the trigger
      # token through the avalanche group.
      sops.secrets.github_runner_pat = {
        sopsFile = ../secrets/avalanche.yaml;
        key = "pat";
        owner = runnerUser;
        group = runnerUser;
        mode = "0400";
        restartUnits = [ "${runnerService}.service" ];
      };

      systemd.services.${runnerService}.serviceConfig.SupplementaryGroups = [ "avalanche" ];

      services.github-runners.${runnerName} = {
        enable = true;
        url = "https://github.com/pelikanade/flake";
        name = runnerName;
        tokenType = "access";
        tokenFile = config.sops.secrets.github_runner_pat.path;
        ephemeral = true;
        replace = true;
        extraLabels = [ runnerName ];
        user = runnerUser;
        group = runnerUser;
      };
    };
}
