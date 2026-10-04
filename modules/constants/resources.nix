{ inputs, ... }: {
  flake.modules.generic.resources = { lib, ... }: {
    options.constants.resources = lib.mkOption {
      type = with lib.types; attrsOf unspecified;
      default = { };
    };

    config.constants.resources = {
      getSecretPath = fileName: "${inputs.self}/modules/secrets/${fileName}";

      # Runtime paths a Home Manager consumer reads by path, so a user-level
      # program never needs its own decryption key. The omp aspect decrypts the
      # DeepSeek and OpenRouter keys for the desktop user at these paths, and
      # its models.yml resolves them with `!cat` when a request needs one.
      userSecretPaths = {
        ompDeepseekApiKey = "/run/secrets/omp-deepseek-api-key";
        ompOpenrouterApiKey = "/run/secrets/omp-openrouter-api-key";
      };
    };
  };
}
