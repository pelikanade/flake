_: {
  flake.modules.nixos.udiskie = {
    services.udisks2.enable = true;
  };

  flake.modules.homeManager.udiskie = {
    services.udiskie.enable = true;

    systemd.user.services.udiskie.Unit.ConditionEnvironment = "WAYLAND_DISPLAY";
  };
}
