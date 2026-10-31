_: {
  flake.modules.homeManager.ghostty =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      systemdUnit = "app-com.mitchellh.ghostty.service";
    in
    {
      programs.ghostty = {
        enable = true;
        settings = {
          mouse-hide-while-typing = false;
          cursor-style = "bar";
          cursor-style-blink = false;
          command = lib.getExe pkgs.fish;
          # Stylix's Ghostty target defaults to its generated theme; use the
          # built-in Nord theme instead.
          theme = lib.mkForce "Nord";
          # The systemd instance starts with --initial-window=false; keep it
          # resident so opening a window never pays GTK startup again.
          quit-after-last-window-closed = false;
        };
      };

      # Home Manager installs the unit (programs.ghostty.systemd) but does not
      # enable it. Enabling it in the graphical session hides Ghostty's GTK
      # startup at login instead of on the first terminal launch.
      xdg.configFile."systemd/user/graphical-session.target.wants/${systemdUnit}".source =
        config.xdg.configFile."systemd/user/${systemdUnit}".source;
    };
}
