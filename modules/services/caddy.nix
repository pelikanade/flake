{
  flake.modules.nixos.caddy = {
    services.caddy = {
      enable = true;
      openFirewall = true;
    };
  };
}
