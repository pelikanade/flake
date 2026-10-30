_: {
  flake.modules.homeManager.obsidian =
    { pkgs, ... }:
    {
      # Obsidian stores vault, sync, and plugin secrets through Electron's
      # `safeStorage`, and Electron picks that backend from `XDG_CURRENT_DESKTOP`.
      # Sway is not one of the desktops it recognises as GNOME-like, so it falls
      # back to the plaintext `basic_text` store and Obsidian reports that no
      # secret store is available. The Secret Service is already running and
      # unlocked in the session (see the `keyring` aspect), so name the backend
      # that talks to it.
      # Electron 43.8.x (43.8.3 in the nixos-26.05 channel of 2026-10-28) rejects
      # a promise while it lazily loads its `webFrame` module for a vault window
      # and prints the `UnhandledPromiseRejectionWarning` through the app at
      # every launch. A launcher that hands the app a stderr pipe whose reader is
      # gone then turns the write of that warning into an uncaught `EPIPE`, and
      # the "A JavaScript error occurred in the main process" dialog comes up
      # before any window does. stderr only ever carries diagnostics here —
      # Obsidian itself logs to stdout, Chromium logs natively — so give it a
      # file: the write can no longer fail, and the diagnostics stay readable
      # under `$XDG_STATE_HOME/obsidian`. Drop this once an Electron release
      # stops warning on that lazy load.
      programs.obsidian = {
        enable = true;
        package =
          (pkgs.obsidian.override {
            commandLineArgs = "--password-store=gnome-libsecret";
          }).overrideAttrs
            (old: {
              postFixup = (old.postFixup or "") + ''
                wrapProgram $out/bin/obsidian --run '
                  log="''${XDG_STATE_HOME:-$HOME/.local/state}/obsidian/stderr.log"
                  mkdir -p "''${log%/*}" 2>/dev/null || log=/dev/null
                  exec 2>>"$log"
                '
              '';
            });
      };
    };

  # Obsidian's bundled `obsidian-cli` only drives a running desktop app, which a
  # headless host cannot provide. `obsidian-headless` is Obsidian's own client
  # for the same account without the app: it operates on vaults from the command
  # line and installs the `ob` executable. nixos-26.05 does not carry it yet, so
  # take the unstable set's copy.
  flake.modules.nixos.obsidian-headless = { pkgs, ... }: {
    environment.systemPackages = [ pkgs.unstable.obsidian-headless ];
  };
}
