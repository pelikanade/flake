{ inputs, ... }:
{
  flake-file.inputs.stylix = {
    url = "github:nix-community/stylix/release-26.05";
    inputs.flake-parts.follows = "flake-parts";
    inputs.nixpkgs.follows = "nixpkgs";
    inputs.systems.follows = "systems";
  };

  flake.modules.nixos.stylix =
    { pkgs, ... }:
    {
      imports = [
        inputs.stylix.nixosModules.stylix
      ];

      stylix = {
        enable = true;
        base16Scheme = "${pkgs.base16-schemes}/share/themes/nord.yaml";
        polarity = "dark";
        cursor = {
          name = "Adwaita";
          package = pkgs.adwaita-icon-theme;
          size = 24;
        };
        icons = {
          enable = true;
          package = pkgs.tela-icon-theme;
          dark = "Tela-dark";
          light = "Tela-dark";
        };
        /*
          Stylix uses these as the primary fonts for application targets and
          inserts them into Fontconfig's default-font lists at order 600.
          modules/services/fonts.nix appends its `fallbackFonts` at order 1500
          through `lib.mkAfter`, producing this precedence:

            Stylix primary -> CJK fallback -> Nerd Font symbols -> emoji

          Keep Stylix's Fontconfig target enabled so the primary fonts remain
          synchronized with application-specific Stylix targets.
        */
        fonts = {
          serif = {
            name = "Noto Serif";
            package = pkgs.noto-fonts;
          };
          sansSerif = {
            name = "Noto Sans";
            package = pkgs.noto-fonts;
          };
          monospace = {
            name = "FiraCode Nerd Font";
            package = pkgs.nerd-fonts.fira-code;
          };
          emoji = {
            name = "Twitter Color Emoji";
            package = pkgs.twitter-color-emoji;
          };
          sizes = {
            terminal = 11;
          };
        };
      };
    };

  flake.modules.homeManager.stylix = _: {
    stylix.targets = {
      firefox.enable = false;
      zed.enable = false;
    };
  };
}
