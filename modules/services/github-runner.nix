{
  flake.modules.nixos.github-runner =
    { lib, ... }:
    let
      runnerName = "neko-sphere";
      runnerUser = "github-runner";
    in
    {
      options.github-runner.imported = lib.mkOption {
        type = lib.types.bool;
        default = true;
        readOnly = true;
        internal = true;
        description = "Whether the GitHub runner module is imported.";
      };

      config = {
        users.groups.${runnerUser} = { };

        users.users.${runnerUser} = {
          isSystemUser = true;
          group = runnerUser;
          description = "GitHub Actions runner";
        };

        services.github-runners.${runnerName} = {
          enable = true;
          url = "https://github.com/pelikanade/flake";
          name = runnerName;
          tokenType = "access";
          ephemeral = true;
          replace = true;
          extraLabels = [ runnerName ];
          user = runnerUser;
          group = runnerUser;
        };
      };
    };
}
