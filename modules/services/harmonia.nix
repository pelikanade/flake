_: {
  # Harmonia serves the host's Nix store directly, so Freezer's builds are
  # available to the tailnet without a copy to object storage. It signs with
  # the cache key clients already trust.
  flake.modules.nixos.harmonia =
    { config, ... }:
    {
      services.harmonia.cache = {
        enable = true;
        signKeyPaths = [ config.sops.secrets.cache-signing-key.path ];
        settings.bind = "127.0.0.1:5000";
      };

      # The signing key is the one the old S3 cache published under, so
      # consumers keep the same trusted-public-keys entry.
      sops.secrets.cache-signing-key = {
        format = "yaml";
        key = "signing-key";
        sopsFile = config.constants.resources.getSecretPath "freezer.yaml";
        owner = "root";
        mode = "0400";
        restartUnits = [ "harmonia.service" ];
      };
    };
}
