{ inputs, ... }:
{
  flake-file.inputs.noctalia = {
    url = "github:noctalia-dev/noctalia";
  };

  # The community plugin felipeartur/ai-usagebar runs this CLI by name.
  flake-file.inputs.ai-usagebar = {
    url = "github:akitaonrails/ai-usagebar";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  flake.modules.nixos.noctalia =
    {
      config,
      pkgs,
      ...
    }:
    let
      secretPaths = config.constants.resources.userSecretPaths;

      # The CLI reads its keys from the environment. Wrap it so the sops
      # secret files are exported into ai-usagebar processes only, not into
      # everything the shell launches.
      aiUsagebar = pkgs.symlinkJoin {
        name = "ai-usagebar-secrets";
        paths = [ inputs.ai-usagebar.packages.${pkgs.stdenv.hostPlatform.system}.default ];
        nativeBuildInputs = [ pkgs.makeWrapper ];
        postBuild = ''
          for program in ai-usagebar ai-usagebar-tui; do
            wrapProgram "$out/bin/$program" \
              --run 'if [ -r ${secretPaths.deepseek_api_key} ]; then export DEEPSEEK_API_KEY="$(cat ${secretPaths.deepseek_api_key})"; fi' \
              --run 'if [ -r ${secretPaths.openrouter_management_key} ]; then openrouter_usagebar_key="$(cat ${secretPaths.openrouter_management_key})"; if [ -n "$openrouter_usagebar_key" ] && [ "$openrouter_usagebar_key" != "REPLACE_WITH_OPENROUTER_MANAGEMENT_KEY" ]; then export OPENROUTER_API_KEY="$openrouter_usagebar_key"; fi; unset openrouter_usagebar_key; fi'
          done
        '';
      };
    in
    {
      imports = [ inputs.noctalia.nixosModules.default ];

      sops.secrets.openrouter_management_key = {
        format = "yaml";
        key = "openrouter_management_key";
        sopsFile = config.constants.resources.getSecretPath "agent-providers.yaml";
        path = secretPaths.openrouter_management_key;
        owner = config.constants.nvirellia.username;
        group = config.users.users.${config.constants.nvirellia.username}.group;
        mode = "0400";
      };

      # The balance bar runs as the desktop account and reads this key by path,
      # so it is declared here as well; the gateway reads its own copy through
      # systemd credentials.
      sops.secrets.deepseek_api_key = {
        format = "yaml";
        key = "deepseek_api_key";
        sopsFile = config.constants.resources.getSecretPath "agent-providers.yaml";
        path = secretPaths.deepseek_api_key;
        owner = config.constants.nvirellia.username;
        group = config.users.users.${config.constants.nvirellia.username}.group;
        mode = "0400";
      };

      environment.systemPackages = [
        # Noctalia drives external monitor brightness through ddcutil.
        pkgs.ddcutil
        # The community ai-usagebar plugin's bar widget and panel.
        aiUsagebar
      ];

      # Noctalia publishes prebuilt binaries on its own cache; following
      # nixpkgs would change the derivations and miss it.
      nix.settings = {
        extra-substituters = [ "https://noctalia.cachix.org" ];
        extra-trusted-public-keys = [
          "noctalia.cachix.org-1:pCOR47nnMEo5thcxNDtzWpOxNFQsBRglJzxWPp3dkU4="
        ];
      };

      programs.noctalia = {
        enable = true;
        systemd.enable = true;
      };
    };

  flake.modules.homeManager.noctalia =
    { ... }:
    {
      imports = [ inputs.noctalia.homeModules.default ];

      programs.noctalia = {
        enable = true;
        # The live settings, pinned as the declarative base layer; the shell's
        # state-dir settings still override it at runtime.
        settings = ./noctalia.toml;
      };

      # Both rows report balances. The wrapper only loads a configured
      # OpenRouter management key; the ordinary inference key belongs to Pi.
      xdg.configFile."ai-usagebar/config.toml".text = ''
        [deepseek]
        enabled = true
        headline = "amount"

        [openrouter]
        enabled = true
        headline = "amount"
      '';
    };
}
