# The Xiaomi POCO F3 / Redmi K40 / Mi 11X that runs NixOS from its boot and
# userdata partitions. The device support, including the kernel and the two
# images the phone boots from, is in modules/devices/alioth.
{
  inputs,
  ...
}:
{
  machines.alioth = {
    system = "aarch64-linux";
    imports = with inputs.self.modules.aspects; [
      base
      server
      tailscale
      k3s
      alioth
    ];
    hardware = {
      networking.hostName = "alioth";
    };

    # The tailnet is the only path another host takes to this node, and the API
    # certificate has to carry the names that path uses: the MagicDNS one and
    # the short one, which is what a client inside the tailnet may type.
    nixosModule =
      { config, ... }:
      let
        tailnet = config.constants.getTailnetFqdn;
      in
      {
        services.k3s.extraFlags = [
          "--tls-san=${tailnet config.networking.hostName}"
          "--tls-san=${config.networking.hostName}"
        ];

        # The phone's network does not reach Docker Hub: a pull from it fails on
        # both address families, so the sandbox image never arrives and every
        # pod sits in `ContainerCreating`. The images the node's own components
        # need come from the store instead, which the workstation fills the way
        # it fills the rest of the system.
        services.k3s.images = [ config.services.k3s.package.airgap-images ];
      };
  };
}
