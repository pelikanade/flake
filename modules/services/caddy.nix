{
  # Caddy terminates public TLS for the site names a host serves. Automatic
  # HTTPS derives both the certificates and the HTTP-to-HTTPS redirect from the
  # names alone, so a machine only declares each name and where it forwards.
  # The upstream is expected on loopback; nothing here opens a port for it.
  flake.modules.nixos.caddy = {
    services.caddy = {
      enable = true;
      openFirewall = true;
    };
  };
}
