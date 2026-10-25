{
  flake.modules.nixos.update-packages-runner =
    { config, pkgs, ... }:
    let
      runnerName = "update-packages";
      runnerUser = "update-packages-runner";
      runnerService = "github-runner-${runnerName}";
      # omp reads its Magpie credentials from $HOME, and the runner module
      # otherwise points HOME at a runtime directory that systemd wipes
      # between ephemeral jobs.
      runnerHome = "/var/lib/update-packages-runner";
      ompExtensions = (pkgs.formats.yaml { }).generate "omp-magpie-config.yml" {
        extensions = [ "${pkgs.selfPackages.omp-magpie}/share/omp/extensions/magpie" ];
      };
    in
    {
      users.groups.${runnerUser} = { };

      users.users.${runnerUser} = {
        isSystemUser = true;
        group = runnerUser;
        description = "Package update GitHub Actions runner";
      };

      sops.secrets.update_packages_runner_pat = {
        sopsFile = ../../secrets/avalanche.yaml;
        key = "pat";
        owner = runnerUser;
        group = runnerUser;
        mode = "0400";
        restartUnits = [ "${runnerService}.service" ];
      };

      sops.secrets.update-packages-magpie-endpoint = {
        format = "yaml";
        key = "endpoint";
        sopsFile = config.constants.resources.getSecretPath "magpie.yaml";
      };
      sops.secrets.update-packages-magpie-api-key = {
        format = "yaml";
        key = "api_key";
        sopsFile = config.constants.resources.getSecretPath "magpie.yaml";
      };

      sops.templates.update-packages-omp-magpie = {
        content = builtins.toJSON {
          endpoint = config.sops.placeholder.update-packages-magpie-endpoint;
          api_key = config.sops.placeholder.update-packages-magpie-api-key;
        };
        path = "${runnerHome}/.omp/agent/magpie.yaml";
        owner = runnerUser;
        group = runnerUser;
        mode = "0400";
        restartUnits = [ "${runnerService}.service" ];
      };

      # The template is rendered before normal services start, so the tree it
      # writes into must exist and belong to the runner user first.
      systemd.tmpfiles.rules = [
        "d ${runnerHome} 0700 ${runnerUser} ${runnerUser} -"
        "d ${runnerHome}/.omp 0700 ${runnerUser} ${runnerUser} -"
        "d ${runnerHome}/.omp/agent 0700 ${runnerUser} ${runnerUser} -"
      ];
      systemd.services.sops-install-secrets.after = [
        "systemd-tmpfiles-setup.service"
        "systemd-tmpfiles-resetup.service"
      ];

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

        # The service sandbox keeps /var read-only except for its own state
        # directories, so the persistent home is declared as one.
        serviceOverrides = {
          StateDirectory = [ "update-packages-runner" ];
        };

        extraEnvironment = {
          HOME = runnerHome;
          PI_CONFIG_FILES = toString ompExtensions;
        };

        extraPackages = with pkgs; [
          bun
          curl
          gawk
          gh
          jq
          nix-update
          nixfmt-rfc-style
          openssh
          ripgrep
          selfPackages.omp
          util-linux
        ];
      };
    };
}
