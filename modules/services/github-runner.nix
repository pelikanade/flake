{
  flake.modules.nixos.github-runner =
    { config, ... }:
    let
      runnerName = "neko-sphere";
      runnerUser = "github-runner";
    in
    {
      users.groups.${runnerUser} = { };

      users.users.${runnerUser} = {
        isSystemUser = true;
        group = runnerUser;
        description = "GitHub Actions runner";
      };

      sops.secrets.github_runner_pat = {
        sopsFile = ../secrets/avalanche.yaml;
        key = "pat";
        owner = runnerUser;
        group = runnerUser;
        mode = "0400";
        restartUnits = [ "github-runner-${runnerName}.service" ];
      };

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
