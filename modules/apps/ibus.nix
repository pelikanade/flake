_: {
  flake.modules.nixos.ibus =
    { pkgs, ... }:
    {
      # GNOME runs IBus itself: the session's D-Bus activation starts
      # ibus-daemon with its panel disabled, so GNOME Shell draws the candidate
      # window and owns the input-source switch. Rime is carried as an IBus
      # engine, with rime-ice as its data.
      i18n.inputMethod = {
        enable = true;
        type = "ibus";
        ibus = {
          # Wayland clients use text-input-v3 through GNOME Shell; XWayland
          # clients reach the same daemon through ibus-x11.
          waylandFrontend = true;
          engines = [
            (pkgs.ibus-engines.rime.override {
              rimeDataPkgs = [ pkgs.rime-ice ];
            })
          ];
        };
      };
    };

  flake.modules.homeManager.ibus =
    { lib, ... }:
    {
      dconf.settings."org/gnome/desktop/input-sources".sources = [
        (lib.hm.gvariant.mkTuple [
          "xkb"
          "us"
        ])
        (lib.hm.gvariant.mkTuple [
          "ibus"
          "rime"
        ])
      ];

      dconf.settings."org/gnome/desktop/wm/keybindings" = {
        switch-input-source = [ "<Control>space" ];
        switch-input-source-backward = [ "<Shift><Control>space" ];
      };

      # ibus-rime hardcodes its user data directory to $HOME/.config/ibus/rime,
      # so this is a home file rather than an xdg.configFile.
      home.file.".config/ibus/rime/default.custom.yaml".text = ''
        patch:
          __include: rime_ice_suggestion:/

          schema_list:
            - schema: rime_ice
      '';

      # Rime only uses the frontend's hard cursor (a bar) when the preedit is
      # the composition and the cursor sits at the insertion point. Its shipped
      # preview/select defaults set `soft_cursor`, which inserts U+2038 (‸) into
      # the preedit and is what GNOME shows as the small caret.
      home.file.".config/ibus/rime/ibus_rime.custom.yaml".text = ''
        patch:
          style/preedit_style: composition
          style/cursor_type: insert
      '';
    };
}
