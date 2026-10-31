{
  flake.modules.nixos.avalanche-runner =
    { config, pkgs, ... }:
    let
      runnerName = "avalanche";
      runnerUser = "avalanche-runner";
      runnerService = "github-runner-${runnerName}";
    in
    {
      environment.systemPackages = [ pkgs.selfPackages.avalanche ];

      users.groups.${runnerUser} = { };

      users.users.${runnerUser} = {
        isSystemUser = true;
        group = runnerUser;
        description = "Avalanche GitHub Actions runner";
      };

      sops.secrets.avalanche_runner_pat = {
        sopsFile = ../../secrets/avalanche.yaml;
        key = "pat";
        owner = runnerUser;
        group = runnerUser;
        mode = "0400";
        restartUnits = [ "${runnerService}.service" ];
      };

      # An ephemeral runner exits and is restarted after every job, so it reads
      # a changed unit on its own. Restarting it during a switch would kill
      # that job, which for a deploy is the one activating this host.
      systemd.services.${runnerService} = {
        serviceConfig.SupplementaryGroups = [ "avalanche" ];
        restartIfChanged = false;
      };

      services.github-runners.${runnerName} = {
        enable = true;
        url = "https://github.com/pelikanade/flake";
        name = runnerName;
        tokenType = "access";
        tokenFile = config.sops.secrets.avalanche_runner_pat.path;
        ephemeral = true;
        replace = true;
        extraLabels = [ runnerName ];
        user = runnerUser;
        group = runnerUser;
      };
    };
}
