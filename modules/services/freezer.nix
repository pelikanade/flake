{ inputs, ... }:
{
  # Freezer publishes this repository's outputs to the signed cache the nix
  # module trusts, so its flake input belongs to this feature.
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

        cache = {
          bucket = "nix-binary-cache";
          endpoint = "https://f24a598cd131f61768fd4e172ec795a1.r2.cloudflarestorage.com";
          signingKey = config.sops.secrets.freezer-signing-key.path;
        };

        repositories = [
          {
            name = "flake";
            url = "https://github.com/pelikanade/flake.git";
            github = "pelikanade/flake";
          }
        ];
      };

      # Freezer never reads the signing key; the Nix process it spawns opens it
      # when copying, so it belongs to the service account and no one else.
      sops.secrets.freezer-signing-key = {
        format = "yaml";
        key = "signing-key";
        sopsFile = config.constants.resources.getSecretPath "freezer.yaml";
        owner = "freezer";
        group = "freezer";
        mode = "0400";
        restartUnits = [ "freezer.service" ];
      };

      sops.secrets.freezer-github-token = {
        format = "yaml";
        key = "github-token";
        sopsFile = config.constants.resources.getSecretPath "freezer.yaml";
        restartUnits = [ "freezer.service" ];
      };

      sops.secrets.freezer-r2-access-key-id = {
        format = "yaml";
        key = "r2-access-key-id";
        sopsFile = config.constants.resources.getSecretPath "freezer.yaml";
        restartUnits = [ "freezer.service" ];
      };

      sops.secrets.freezer-r2-secret-access-key = {
        format = "yaml";
        key = "r2-secret-access-key";
        sopsFile = config.constants.resources.getSecretPath "freezer.yaml";
        restartUnits = [ "freezer.service" ];
      };

      sops.templates.freezer-environment = {
        content = ''
          GITHUB_TOKEN=${config.sops.placeholder.freezer-github-token}
          AWS_ACCESS_KEY_ID=${config.sops.placeholder.freezer-r2-access-key-id}
          AWS_SECRET_ACCESS_KEY=${config.sops.placeholder.freezer-r2-secret-access-key}
        '';
        restartUnits = [ "freezer.service" ];
      };
    };
}
