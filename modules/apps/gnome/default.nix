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
    { lib, pkgs, ... }:
    let
      # The shell ignores a numbered workspace binding that points past the last
      # workspace, and dynamic workspaces drop trailing empties. Super+<n> has to
      # address a workspace that always exists, so the count is fixed.
      workspaces = lib.range 1 9;

      numbered =
        prefix: valueFor:
        lib.listToAttrs (map (n: lib.nameValuePair "${prefix}-${toString n}" (valueFor n)) workspaces);

      switchToWorkspace = numbered "switch-to-workspace" (n: [ "<Super>${toString n}" ]);
      moveToWorkspace = numbered "move-to-workspace" (n: [ "<Super><Shift>${toString n}" ]);

      # GNOME Shell also claims Super+<n> for the nth favorite application;
      # release it so the accelerators only switch workspaces.
      switchToApplication = numbered "switch-to-application" (_: [ ]);
    in
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
      }
      // switchToApplication;

      dconf.settings."org/gnome/desktop/wm/keybindings" = switchToWorkspace // moveToWorkspace;

      dconf.settings."org/gnome/mutter".dynamic-workspaces = false;
      dconf.settings."org/gnome/desktop/wm/preferences".num-workspaces = lib.length workspaces;

      # GNOME resolves fonts itself for its own applications, ahead of what
      # Fontconfig says, so the grayscale antialiasing the stem-darkening tweaks
      # are calibrated for is named here as well.
      dconf.settings."org/gnome/desktop/interface".font-antialiasing = "grayscale";

      home.packages = [
        pkgs.gnomeExtensions.dash-to-dock
        pkgs.gnomeExtensions.dash-to-panel

        pkgs.wl-clipboard
      ];

      home.sessionVariables = {
        NIXOS_OZONE_WL = "1";
        ELECTRON_OZONE_PLATFORM_HINT = "auto";
      };
    };
}
