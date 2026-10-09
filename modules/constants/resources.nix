{ inputs, ... }: {
  flake.modules.generic.resources = { lib, ... }: {
    options.constants.resources = lib.mkOption {
      type = with lib.types; attrsOf unspecified;
      default = { };
    };

    config.constants.resources = {
      getSecretPath = fileName: "${inputs.self}/modules/secrets/${fileName}";

      # Runtime paths provisioned by NixOS for Home Manager secret consumers.
      userSecretPaths.ompMagpie = "/run/secrets/omp-magpie";
    };
  };
}
