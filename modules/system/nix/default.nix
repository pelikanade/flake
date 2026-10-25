{ inputs, ... }: {
  flake.modules.nixos.nix =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    {
      nix = {
        package = pkgs.nix;
        channel.enable = false;
        registry = {
          noa.flake = inputs.self;
        };
        settings = lib.mkMerge [
          {
            experimental-features = [
              "nix-command"
              "flakes"
            ];
            extra-substituters = [ "https://nix-community.cachix.org" ];
            trusted-public-keys = [
              "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
            ];
            trusted-users = [ "@wheel" ];
          }
          (lib.mkIf config.services.tailscale.enable {
            extra-substituters = [ "http://${config.constants.getTailnetFqdn "nsphere-cache"}" ];
            trusted-public-keys = [
              "freezer-cache-1:frU02BGsL4XIHxMWogpWoZWNDzLcgwH4Iu8XoPs6WyI="
            ];
          })
        ];

        # Suppress nix-shell channel errors on a flake system
        nixPath = [ "/etc/nix/path" ];

        gc = {
          automatic = true;
          dates = "weekly";
          options = "--delete-older-than 7d";
        };
      };

      environment.etc."nix/path/nixpkgs".source = inputs.nixpkgs;

      nixpkgs.config.allowUnfree = true;

      system.stateVersion = "26.05";
    };
}
