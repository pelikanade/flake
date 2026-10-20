{ inputs, ... }:
{
  flake-file.inputs.nix-flatpak.url = "github:gmodena/nix-flatpak/?ref=latest";

  flake.modules.nixos.flatpak = { pkgs, ... }: {
    services.flatpak.enable = true;

    xdg.portal = {
      enable = true;
      extraPortals = with pkgs; [
        xdg-desktop-portal-gtk
      ];
      config.common = {
        default = [ "gtk" ];
        "org.freedesktop.impl.portal.Secret" = [ "gnome-keyring" ];
      };
    };
  };

  flake.modules.homeManager.flatpak =
    { osConfig, ... }:
    {
      imports = [ inputs.nix-flatpak.homeManagerModules.nix-flatpak ];

      services.flatpak = {
        enable = true;

        # Flatpak names the sandbox's timezone by matching TZDIR against the
        # target of /etc/localtime. nixpkgs gives PAM sessions
        # `TZDIR=/etc/zoneinfo`, which matches that target, but hands every
        # systemd unit `TZDIR=/nix/store/…-tzdata-…/share/zoneinfo` through
        # `systemd.globalEnvironment`; an application started from such a unit
        # — the bar's launcher is one — inherits a store path instead, the
        # match fails, and everything in its sandbox reads UTC while the host
        # stays on local time. Name the zone in the sandbox so the match is
        # not needed at all.
        overrides.settings.global.Environment.TZ = osConfig.time.timeZone;
      };
    };
}
