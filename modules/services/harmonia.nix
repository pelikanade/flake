_: {
  flake.modules.nixos.harmonia =
    { config, ... }:
    {
      services.harmonia.cache = {
        enable = true;
        signKeyPaths = [ config.sops.secrets.cache-signing-key.path ];
        settings.bind = "127.0.0.1:5000";
      };

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
