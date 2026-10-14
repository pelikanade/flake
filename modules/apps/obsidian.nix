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
      programs.obsidian = {
        enable = true;
        package = pkgs.obsidian.override {
          commandLineArgs = "--password-store=gnome-libsecret";
        };
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
