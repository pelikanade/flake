{
  flake.modules.nixos.ssh = {
    services.openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        PermitRootLogin = "prohibit-password";
      };
    };

    # Reachable on the tailnet only: `tailnet0` is the system interface of the
    # sing-box Tailscale endpoint, and `services.openssh.openFirewall` stays off
    # so no interface without that endpoint accepts SSH.
    networking.firewall.interfaces.tailnet0.allowedTCPPorts = [ 22 ];
  };
}
