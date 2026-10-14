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

    # Nothing here names the tailnet: a peer reaches this host's tailnet address,
    # which sing-box's userspace endpoint delivers to loopback, so no packet of
    # such a connection reaches the firewall, and a rule for an interface would
    # match nothing.
    #
    # SSH is instead admitted on every interface, public address included:
    # nixos-26.05 defaults `services.openssh.openFirewall` to true and opens
    # `allowedTCPPorts`. Setting it to false keeps SSH through the endpoint's
    # loopback delivery, and through the host itself, while closing the rest —
    # but it also drops a LAN client that logs in directly, which is the only
    # remote path while the endpoint is not enrolled.
  };
}
