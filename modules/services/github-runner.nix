{
  flake.modules.nixos.github-runner =
    { config, lib, ... }:
    let
      runnerNames = [
        "neko-sphere-1"
        "neko-sphere-2"
      ];
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

      services.github-runners = lib.genAttrs runnerNames (name: {
        enable = true;
        url = "https://github.com/pelikanade/flake";
        inherit name;
        tokenFile = config.sops.secrets.github_runner_token.path;
        tokenType = "access";
        ephemeral = true;
        replace = true;
        extraLabels = [ "neko-sphere" ];
        user = deployUser;
        group = deployUser;
      });
    };
}
