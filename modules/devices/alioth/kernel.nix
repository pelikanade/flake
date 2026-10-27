# The kernel and device tree of the Xiaomi POCO F3 / Redmi K40 / Mi 11X
# (codename alioth).
{
  flake.modules.nixos.alioth =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    {
      options.alioth = {
        kernel = lib.mkOption {
          type = lib.types.package;
          description = "The kernel the phone boots.";
        };

        deviceTree = lib.mkOption {
          type = lib.types.str;
          description = "The device tree the vendor boot image carries.";
        };
      };

      config.alioth = {
        # The phone's kernel is a Linux 6.19.6 fork that the postmarketOS
        # SM8250 port maintains, because upstream has no device tree for this
        # phone. The fork, its configuration, and the patch adding the device
        # tree, panel, and touchscreen drivers are the ones the port is tested
        # with; `kernel-config.aarch64` is the complete configuration this build
        # uses, and the symbols this device needs changed are changed in it.
        kernel = pkgs.linuxManualConfig {
          version = "6.19.6";
          modDirVersion = "6.19.6";
          src = pkgs.buildPackages.fetchurl {
            url = "https://gitlab.postmarketos.org/soc/qualcomm-sm8250/linux/-/archive/6.19.6/linux-6.19.6.tar.gz";
            hash = "sha256-HW14XQybSwPRYUv3TRurqljxoC6WnUux5rrksi4rNZk=";
          };
          configfile = ./kernel-config.aarch64;
          kernelPatches = [
            {
              name = "alioth-device-tree";
              patch = ./0001-alioth-dts-panel-touchscreen.patch;
            }
            {
              name = "alioth-usb-c-sink";
              patch = ./0002-alioth-usb-c-sink.patch;
            }
          ];
        };

        deviceTree = "${config.alioth.kernel}/dtbs/qcom/sm8250-xiaomi-alioth.dtb";
      };
    };
}
