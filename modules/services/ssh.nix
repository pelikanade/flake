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

    # Nothing here names the tailnet: a peer reaches this host's tailnet address
    # on `tailscale0`, which the firewall trusts as an interface, so SSH over the
    # tailnet is admitted there rather than by a port.
    #
    # SSH is instead admitted on every interface, public address included:
    # nixos-26.05 defaults `services.openssh.openFirewall` to true and opens
    # `allowedTCPPorts`. Setting it to false keeps SSH from the tailnet, through
    # the trusted interface, and from the host itself, while closing the rest —
    # but it also drops a LAN client that logs in directly, which is the only
    # remote path while the node is not enrolled in the tailnet.
  };
}
