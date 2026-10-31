# The activation step that makes a configuration bootable is
# `installBootLoader`, which a NixOS system with no `boot.loader.*` fills with a
# script that only warns when it runs. Pointing it at the boot partitions makes
# a switch write the images the configuration carries, so one `just rdeploy` is
# the whole update for a kernel, device tree or command line change and no
# fastboot session is needed.
_: {
  flake.modules.nixos.alioth =
    {
      config,
      pkgs,
      ...
    }:
    {
      boot.loader.external.enable = true;

      boot.loader.external.installHook = pkgs.writeShellScript "alioth-install-bootloader" ''
        set -eu

        exec ${config.system.build.aliothWriteBoot}/bin/alioth-write-boot \
          ${config.system.build.aliothBootImage} \
          ${config.system.build.aliothVendorBoot}
      '';
    };
}
