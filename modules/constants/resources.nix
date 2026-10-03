{ inputs, ... }: {
  flake.modules.generic.resources = { lib, ... }: {
    options.constants.resources = lib.mkOption {
      type = with lib.types; attrsOf unspecified;
      default = { };
    };

    config.constants.resources = {
      getSecretPath = fileName: "${inputs.self}/modules/secrets/${fileName}";

      # Runtime paths of secrets an unprivileged consumer reads by path. The
      # usage bar is the only one: every agent credential reaches its service
      # through systemd credentials instead.
      userSecretPaths = {
        deepseek_api_key = "/run/secrets/deepseek_api_key";
        openrouter_management_key = "/run/secrets/openrouter_management_key";
      };
    };
  };
}
