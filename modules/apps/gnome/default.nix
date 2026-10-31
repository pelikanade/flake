{
  flake.modules.nixos.gnome =
    { pkgs, ... }:
    {
      # The workstation desktop. Enabling GNOME also brings up what it cannot
      # run without — dconf, the GNOME and GTK XDG portals, gnome-keyring and
      # gcr's ssh agent, upower, udisks2, libinput, power-profiles-daemon,
      # NetworkManager and Bluetooth — and installs GNOME's core shell and core
      # apps: nautilus, papers, loupe, gnome-system-monitor and gnome-console
      # among them. Those are what replace the KDE and XFCE tools the Hyprland
      # session carried (Dolphin, Atril, Ristretto, xarchiver, tumbler), and
      # `programs.seahorse.enable` comes with them for the keyring front end.
      services.desktopManager.gnome.enable = true;

      # GDM offers one session, and naming it keeps the Wayland session the
      # default one rather than leaving the choice to GDM's own memory.
      services.displayManager.defaultSession = "gnome";

      # The archive manager is not part of GNOME's core apps, and gnome-tweaks
      # is the window onto the extension, startup-app and titlebar settings.
      # Nautilus ships the `org.freedesktop.FileManager1` service file itself,
      # with a plain `Exec`, so Dolphin's broken D-Bus activation needs no
      # replacement here.
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

        # Enabling an extension both installs its package into the profile
        # (which is what puts it on the shell's search path) and names it in
        # `org.gnome.shell.enabled-extensions`.
        extensions = [
          # 615 — AppIndicator and KStatusNotifierItem Support
          { package = pkgs.gnomeExtensions.appindicator; }
          # 3193 — Blur my Shell
          { package = pkgs.gnomeExtensions.blur-my-shell; }
          # 517 — Caffeine
          { package = pkgs.gnomeExtensions.caffeine; }
          # 307 — Dash to Dock
          { package = pkgs.gnomeExtensions.dash-to-dock; }
          # 94 — Kimpanel: fcitx5's input panel through KDE's kimpanel protocol.
          { package = pkgs.gnomeExtensions.kimpanel; }
          # 6807 — System Monitor
          { package = pkgs.gnomeExtensions.system-monitor; }
          # 7065 — Tiling Shell: keyboard-driven tiling and snap layouts.
          { package = pkgs.gnomeExtensions.tiling-shell; }
          # 8594 — Vicinae: the launcher's shell-side half (clipboard events and
          # window management). The daemon is the `vicinae` aspect.
          { package = pkgs.gnomeExtensions.vicinae; }
        ];
      };

      # The screenshot chords the previous session used, on GNOME's own
      # screenshot machinery: the interactive UI, which opens on area selection,
      # and the immediate full-screen capture that lands in ~/Pictures/Screenshots.
      # GNOME's defaults (`Print`, `<Shift>Print`) stay bound alongside them, and
      # `Alt+Print`, the window capture, is left alone.
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
      # are calibrated for is named here as well; see docs/font-rendering.md.
      dconf.settings."org/gnome/desktop/interface".font-antialiasing = "grayscale";

      home.packages = [
        # Installed but deliberately left out of `enabled-extensions`: Dash to
        # Panel and Dash to Dock both take over the dash, so enabling both
        # draws two of them. The Extensions app switches between them.
        pkgs.gnomeExtensions.dash-to-panel

        # A Wayland-session CLI dependency, kept beside the desktop that
        # provides the clipboard.
        pkgs.wl-clipboard
      ];

      # Electron and Chromium applications follow these, as they do on NixOS
      # users' Wayland sessions generally; without them the Electron apps here
      # stay on XWayland.
      home.sessionVariables = {
        NIXOS_OZONE_WL = "1";
        ELECTRON_OZONE_PLATFORM_HINT = "auto";
      };
    };
}
