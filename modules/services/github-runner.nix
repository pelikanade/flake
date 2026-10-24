{
  flake.modules.nixos.github-runner =
    { config, ... }:
    let
      runnerName = "neko-sphere";
      deployUser = "github-runner";
    in
    {
      users.groups.${deployUser} = { };

      users.users.${deployUser} = {
        isSystemUser = true;
        group = deployUser;
        description = "GitHub Actions runner";
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
          SupplementaryGroups = [ "avalanche" ];
        };
      };
    };
}
