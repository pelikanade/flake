{ inputs, ... }: {
  flake.modules.generic.resources = { lib, ... }: {
    options.constants.resources = lib.mkOption {
      type = with lib.types; attrsOf unspecified;
      default = { };
    };

    config.constants.resources = {
      getSecretPath = fileName: "${inputs.self}/modules/secrets/${fileName}";

      # Runtime paths a Home Manager consumer reads by path, so a user-level
      # program never needs its own decryption key. Empty today: every secret is
      # consumed by a NixOS service, and magpie.service alone holds the provider
      # credentials. Add an entry here with the first Home Manager consumer.
      userSecretPaths = { };
    };
  };
}
