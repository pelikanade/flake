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

  flake.modules.homeManager.flatpak = {
    imports = [ inputs.nix-flatpak.homeManagerModules.nix-flatpak ];

    services.flatpak = {
      enable = true;
      packages = [
        "com.slack.Slack"
        "io.github.kolunmi.Bazaar"
        "org.telegram.desktop"
        "org.localsend.localsend_app"
        "io.missioncenter.MissionCenter"
        "io.github.pwr_solaar.solaar"
        "com.qq.QQ"
        "com.tencent.WeChat"
        "com.tencent.wemeet"
      ];
    };
  };
}
