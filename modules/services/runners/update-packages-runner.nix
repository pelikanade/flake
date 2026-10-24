{
  flake.modules.nixos.update-packages-runner =
    { config, pkgs, ... }:
    let
      runnerName = "update-packages";
      runnerUser = "update-packages-runner";
      runnerService = "github-runner-${runnerName}";
    in
    {
      users.groups.${runnerUser} = { };

      users.users.${runnerUser} = {
        isSystemUser = true;
        group = runnerUser;
        description = "Package update GitHub Actions runner";
      };

      # The update workflow registers this runner with the same repository
      # access PAT as the deploy runner; both are separate registrations on
      # this host, so each gets its own unreadable-by-others copy.
      sops.secrets.update_packages_runner_pat = {
        sopsFile = ../../secrets/avalanche.yaml;
        key = "pat";
        owner = runnerUser;
        group = runnerUser;
        mode = "0400";
        restartUnits = [ "${runnerService}.service" ];
      };

      services.github-runners.${runnerName} = {
        enable = true;
        url = "https://github.com/pelikanade/flake";
        name = runnerName;
        tokenType = "access";
        tokenFile = config.sops.secrets.update_packages_runner_pat.path;
        ephemeral = true;
        replace = true;
        extraLabels = [ runnerName ];
        user = runnerUser;
        group = runnerUser;

        # The workflow calls these directly instead of entering a nix shell:
        # the scripts run under python3 and use git and jq, nix-update formats
        # with nixfmt, the repair and review agents are omp, the agent reaches
        # for ripgrep and openssh, and the deploy dispatch uses gh. Nix and
        # git come from the runner service itself. omp is this flake's locked
        # output, so the workflow does not build .#omp per run.
        extraPackages = with pkgs; [
          gh
          jq
          nix-update
          nixfmt-rfc-style
          openssh
          python3
          ripgrep
          selfPackages.omp
        ];
      };
    };
}
