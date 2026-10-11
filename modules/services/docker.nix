{
  flake.modules.nixos.docker =
    { config, lib, ... }:
    {
      virtualisation.docker = {
        enable = true;
        # The control socket stays local; only trusted host services receive access.
        listenOptions = [ "/run/docker.sock" ];
      };

      # sing-box redirects container TCP egress to its host-local listener.
      # Accept those translated flows without trusting the entire Docker bridge.
      networking.firewall.extraInputRules =
        lib.mkIf (config.services.sing-box.enable && config.networking.firewall.backend == "nftables")
          ''
            iifname "docker0" meta l4proto tcp ct status dnat counter accept comment "Docker egress redirected by sing-box"
          '';
    };
}
