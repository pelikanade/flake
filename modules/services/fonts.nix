{ lib, ... }:
let
  /*
    Stylix inserts each primary into Fontconfig at order 600; `lib.mkAfter`
    assigns these entries order 1500, so they are consulted only after the
    primary font lacks a glyph.
  */
  fallbackFonts = {
    serif = lib.mkAfter [
      "Noto Serif CJK SC"
      "Symbols Nerd Font"
      "Twitter Color Emoji"
    ];
    sansSerif = lib.mkAfter [
      "Noto Sans CJK SC"
      "Symbols Nerd Font"
      "Twitter Color Emoji"
    ];
    monospace = lib.mkAfter [
      "Noto Sans Mono CJK SC"
      "Symbols Nerd Font Mono"
      "Noto Sans Symbols"
      "Noto Sans Symbols 2"
      "Twitter Color Emoji"
    ];
  };
in
{
  flake.modules.nixos.fonts = { pkgs, ... }: {
    fonts = {
      fontDir.enable = true;
      packages = with pkgs; [
        noto-fonts
        noto-fonts-cjk-sans
        noto-fonts-cjk-serif
        twitter-color-emoji
        source-han-sans
        source-han-serif
        wqy_microhei
        inter

        fira-code
        nerd-fonts.fira-code

        nerd-fonts.symbols-only
      ];

      enableGhostscriptFonts = true;
      enableDefaultPackages = true;

      fontconfig.defaultFonts = fallbackFonts;
    };
  };

  flake.modules.homeManager.fonts.fonts.fontconfig = {
    enable = true;
    defaultFonts = fallbackFonts;
  };
}
