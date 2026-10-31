{
  flake.modules.nixos.gnome =
    { pkgs, ... }:
    {
      services.desktopManager.gnome.enable = true;

      services.displayManager.defaultSession = "gnome";

      environment.systemPackages = with pkgs; [
        file-roller
        gnome-tweaks
      ];
    };

  flake.modules.homeManager.gnome =
    { pkgs, ... }:
    {
      programs.gnome-shell = {
        enable = true;

        extensions = [
          # 615 — AppIndicator and KStatusNotifierItem Support
          { package = pkgs.gnomeExtensions.appindicator; }
          # 3193 — Blur my Shell
          { package = pkgs.gnomeExtensions.blur-my-shell; }
          # 517 — Caffeine
          { package = pkgs.gnomeExtensions.caffeine; }
          # 307 — Dash to Dock
          { package = pkgs.gnomeExtensions.dash-to-dock; }
          # 779 — Clipboard Indicator: the session's clipboard history.
          { package = pkgs.gnomeExtensions.clipboard-indicator; }
          # 6807 — System Monitor
          { package = pkgs.gnomeExtensions.system-monitor; }
          # 7065 — Tiling Shell: keyboard-driven tiling and snap layouts.
          { package = pkgs.gnomeExtensions.tiling-shell; }
        ];
      };

      dconf.settings."org/gnome/shell/keybindings" = {
        show-screenshot-ui = [
          "Print"
          "<Super><Shift>s"
        ];
        screenshot = [
          "<Shift>Print"
          "<Super><Shift>p"
        ];
      };

      # GNOME resolves fonts itself for its own applications, ahead of what
      # Fontconfig says, so the grayscale antialiasing the stem-darkening tweaks
      # are calibrated for is named here as well.
      dconf.settings."org/gnome/desktop/interface".font-antialiasing = "grayscale";

      home.packages = [
        pkgs.gnomeExtensions.dash-to-panel

        pkgs.wl-clipboard
      ];

      home.sessionVariables = {
        NIXOS_OZONE_WL = "1";
        ELECTRON_OZONE_PLATFORM_HINT = "auto";
      };
    };
}
