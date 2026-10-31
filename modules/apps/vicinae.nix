{
  flake.modules.homeManager.vicinae =
    { config, lib, ... }:
    {
      # The launcher that replaces Noctalia's. The daemon runs as a user service
      # for the whole graphical session, so the hotkey below always has an IPC
      # socket to talk to; the shell-side companion extension is in the `gnome`
      # aspect.
      programs.vicinae = {
        enable = true;
        systemd.enable = true;
      };

      # GNOME's Super+Space switches input sources, a job fcitx5 owns in this
      # session, so clear the chord and hand it to the launcher through the
      # custom-keybinding mechanism. `vicinae toggle` talks to the running
      # server; a second press closes the window again.
      dconf.settings = {
        "org/gnome/desktop/wm/keybindings" = {
          switch-input-source = [ ];
          switch-input-source-backward = [ ];
        };

        "org/gnome/settings-daemon/plugins/media-keys" = {
          custom-keybindings = [
            "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/vicinae/"
          ];
        };

        "org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/vicinae" = {
          name = "Vicinae";
          command = "${lib.getExe config.programs.vicinae.package} toggle";
          binding = "<Super>space";
        };
      };
    };
}
