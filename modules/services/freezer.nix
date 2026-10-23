{ inputs, ... }:
{
  # Freezer builds this repository's flake outputs on neko-sphere; Harmonia
  # serves the resulting store paths over the tailnet. The flake input still
  # belongs to this feature.
  flake-file.inputs.freezer = {
    url = "github:pelikanade/freezer";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  flake.modules.nixos.freezer =
    { config, ... }:
    {
      imports = [ inputs.freezer.nixosModules.default ];

      services.freezer = {
        enable = true;

        # The generated environment file holds the credentials; the template's
        # path is outside the store, and systemd reads it as root.
        environmentFile = config.sops.templates.freezer-environment.path;
        publicUrl = "https://${config.constants.getTailnetFqdn "nsphere-freezer"}";
        pollInterval = "10m";

        repositories = [
          {
            name = "flake";
            url = "https://github.com/pelikanade/flake.git";
            github = "pelikanade/flake";
          }
        ];
      };

      sops.secrets.freezer-github-token = {
        format = "yaml";
        key = "github-token";
        sopsFile = config.constants.resources.getSecretPath "freezer.yaml";
        restartUnits = [ "freezer.service" ];
      };

      sops.templates.freezer-environment = {
        content = ''
          GITHUB_TOKEN=${config.sops.placeholder.freezer-github-token}
        '';
        restartUnits = [ "freezer.service" ];
      };
    };
}
