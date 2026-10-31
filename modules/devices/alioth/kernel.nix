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
