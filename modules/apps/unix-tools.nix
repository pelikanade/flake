{ inputs, ... }: {
  flake-file.inputs.nix-index-database = {
    url = "github:nix-community/nix-index-database";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  flake.modules.homeManager.unix-tools = { config, pkgs, ... }: {
    imports = [
      inputs.nix-index-database.homeModules.nix-index
    ];

    home.packages = with pkgs; [
      devenv
      any-nix-shell
      fastfetch
      nix-output-monitor # https://github.com/maralorn/nix-output-monitor
      dust
      duf
      cachix
      asciinema
      tailspin
      isd
    ];

    programs.ripgrep.enable = true;

    programs.ssh = {
      enable = true;
      enableDefaultConfig = false;
    };

    programs.direnv = {
      enable = true;
      nix-direnv.enable = true;
      config.whitelist.prefix = [ "${config.home.homeDirectory}/.herdr/worktrees/" ];
    };

    programs.zoxide = {
      enable = true;
      enableFishIntegration = true;
    };

    programs.lazygit = {
      enable = true;
      settings = {
        git = {
          commit.signOff = true;
          overrideGpg = true;
        };
      };
    };

    programs.gh = {
      enable = true;
      gitCredentialHelper.enable = true;
      settings = {
        git_protocol = "https";
      };
    };

    # Replace command-not-found with nix-index and comma
    programs.nix-index-database.comma.enable = true;
    programs.command-not-found.enable = false;
    programs.nix-index = {
      enable = true;
      enableFishIntegration = true;
    };

    # Modern unix series
    programs.eza = {
      enable = true;
      enableFishIntegration = true;
    };

    programs.atuin = {
      enable = true;
      enableFishIntegration = true;
      flags = [
        "--disable-up-arrow"
      ];
      settings = {
        ai = {
          enabled = true;
          send_last_command = true;
        };
        auto_sync = false;
        update_check = false;
        style = "compact";
        prefers_reduced_motion = true;
        sync.records = false;
      };
    };
  };
}
