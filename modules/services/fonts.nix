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

  /*
    FreeType's stem darkening, which is what keeps medium and small text
    readable on low-density panels, plus the Qt switch that stops variable fonts
    from being synthesized bold on top of it. Both are read when libfreetype and
    Qt initialise, so they have to be in the session environment rather than a
    shell's, and every application that draws text needs them.

    The `darkening-parameters` are (x, y) pairs: the x values are the font sizes
    in 1/64 px where darkening changes, the y values how much it darkens. These
    are the amounts measured to keep small glyphs legible without making larger
    ones heavy.
  */
  renderingEnvironment = {
    FREETYPE_PROPERTIES = lib.concatStringsSep " " [
      "autofitter:no-stem-darkening=0"
      "autofitter:darkening-parameters=500,400,1000,400,2500,400,4000,0"
      "cff:no-stem-darkening=0"
      "type1:no-stem-darkening=0"
      "t1cid:no-stem-darkening=0"
    ];
    QT_NO_SYNTHESIZED_BOLD = "1";
  };

  /*
    Stem darkening has little to work with on the smallest sizes, so Fontconfig
    emboldens them as well. `pixelsize` is the size a renderer asks for once it
    has resolved the requested one, which is what makes this a rule about what is
    actually drawn.
  */
  emboldenSmallText = ''
    <?xml version="1.0"?>
    <!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
    <fontconfig>
      <description>Embolden text below 14px, where stem darkening has little to work with</description>

      <match target="font">
        <test name="pixelsize" compare="less">
          <double>14.0</double>
        </test>
        <edit name="embolden" mode="assign">
          <bool>true</bool>
        </edit>
      </match>
    </fontconfig>
  '';

  /*
    An icon font draws single symbols on a wide grid, so both the emboldening
    above and hinting inflate it until it stops matching the text beside it.
    This rule has to be read after the one that emboldens, which is what its file
    name's higher number is for. Add a family here when a newly installed icon
    font renders too heavy; icon fonts a page delivers itself are beyond a
    `target="font"` rule and stay untouched.
  */
  iconFonts = ''
    <?xml version="1.0"?>
    <!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
    <fontconfig>
      <description>Keep icon fonts out of the small-text emboldening and hinting</description>

      <match target="font">
        <test name="family" qual="any" compare="eq">
          <string>Symbols Nerd Font</string>
        </test>
        <edit name="hinting" mode="assign">
          <bool>false</bool>
        </edit>
        <edit name="embolden" mode="assign">
          <bool>false</bool>
        </edit>
      </match>

      <match target="font">
        <test name="family" qual="any" compare="eq">
          <string>Symbols Nerd Font Mono</string>
        </test>
        <edit name="hinting" mode="assign">
          <bool>false</bool>
        </edit>
        <edit name="embolden" mode="assign">
          <bool>false</bool>
        </edit>
      </match>
    </fontconfig>
  '';

  # The rules the session and the Flatpak sandbox both apply; the session gets
  # them through Home Manager's conf.d, the sandbox through its own
  # `FONTCONFIG_FILE`, and both read them from this one directory.
  renderingConfs = {
    "20-stem-darkening-embolden" = emboldenSmallText;
    "70-icon-fonts-no-embolden" = iconFonts;
  };
in
{
  flake.modules.nixos.fonts =
    { pkgs, ... }:
    {
      options.fontconfigRendering = {
        dir = lib.mkOption {
          type = lib.types.path;
          readOnly = true;
          description = ''
            Directory holding the Fontconfig rules this desktop applies to its
            own sessions and passes into sandboxes.
          '';
        };

        environment = lib.mkOption {
          type = lib.types.attrsOf lib.types.str;
          readOnly = true;
          description = ''
            Session variables the rendering stack reads when it initialises,
            for consumers that have to set them again (the Flatpak sandbox).
          '';
        };
      };

      config = {
        fontconfigRendering = {
          dir = pkgs.runCommand "fontconfig-rendering" { } (
            "mkdir -p $out\n"
            + lib.concatMapStringsSep "\n" (
              name: "install -m 644 ${pkgs.writeText "${name}.conf" renderingConfs.${name}} $out/${name}.conf"
            ) (lib.attrNames renderingConfs)
          );

          environment = renderingEnvironment;
        };

        # PAM hands these to the session early, so the display manager, every
        # application it launches and the systemd user units (Ghostty's) all
        # see them.
        environment.sessionVariables = renderingEnvironment;

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
    };

  flake.modules.homeManager.fonts =
    { osConfig, ... }:
    {
      fonts.fontconfig = {
        enable = true;
        defaultFonts = fallbackFonts;

        # Stem darkening renders correctly only with grayscale antialiasing, and
        # the light hinting style is what keeps the darkened stems from being
        # reshaped. NixOS' `fontconfig` package enables both, so this pins the
        # choice rather than changing it.
        hinting = "slight";
        subpixelRendering = "none";

        configFile = {
          stem-darkening-embolden = {
            enable = true;
            priority = 20;
            source = "${osConfig.fontconfigRendering.dir}/20-stem-darkening-embolden.conf";
          };
          icon-fonts-no-embolden = {
            enable = true;
            priority = 70;
            source = "${osConfig.fontconfigRendering.dir}/70-icon-fonts-no-embolden.conf";
          };
        };
      };
    };
}
