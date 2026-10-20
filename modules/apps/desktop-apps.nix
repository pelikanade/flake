_: {
  # Solaar opens the Logitech receivers' hidraw nodes directly, and the rules
  # that grant a seated user access live in the package's separate `udev` output
  # instead of its runtime closure. Install them so it works without root.
  flake.modules.nixos.desktop-apps = { pkgs, ... }: {
    services.udev.packages = [ pkgs.logitech-udev-rules ];
  };

  flake.modules.homeManager.desktop-apps =
    { pkgs, ... }:
    {
      home.packages = with pkgs; [
        bazaar
        localsend
        mission-center
        qq
        slack
        solaar
        telegram-desktop
        wechat
        wemeet
      ];
    };
}
