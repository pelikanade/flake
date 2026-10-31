{
  flake.modules.nixos.alioth =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      # The phone's own firmware, taken from the port's extraction of the
      # vendor images. The ADSP, CDSP, SLPI, and Venus firmware blobs live
      # here, and so does the GPU's zap shader as
      # `qcom/sm8250/xiaomi/alioth/a650_zap.mbn`: that is the name the device
      # tree gives it, and the image is the phone's own, signed for this
      # handset rather than the generic one `linux-firmware` ships. The rest
      # of the GPU firmware comes from linux-firmware.
      vendorFirmware = pkgs.buildPackages.runCommand "alioth-firmware" { } ''
        mkdir -p $out
        cp -a ${
          pkgs.buildPackages.fetchzip {
            url = "https://github.com/N1kroks/firmware-xiaomi-alioth/archive/95dfcdf6b154c00af3e093db82015cda90f4299a.tar.gz";
            hash = "sha256-hk/r6p0/d/YLii1B4WHp9I9Y+QBfZOTmYefWfRNa7Lk=";
          }
        }/* $out/
      '';

      radioFirmware = pkgs.buildPackages.runCommand "alioth-radio-firmware" { } ''
        mkdir -p $out/lib/firmware/ath11k $out/lib/firmware/qca
        cp -a ${pkgs.buildPackages.linux-firmware}/lib/firmware/ath11k/QCA6390 \
          $out/lib/firmware/ath11k/
        cp -a \
          ${pkgs.buildPackages.linux-firmware}/lib/firmware/qca/htbtfw20.tlv \
          ${pkgs.buildPackages.linux-firmware}/lib/firmware/qca/htnv20.bin \
          $out/lib/firmware/qca/
      '';

      gpuFirmware = pkgs.buildPackages.runCommand "alioth-gpu-firmware" { } ''
        mkdir -p $out/lib/firmware/qcom
        cp -a \
          ${pkgs.buildPackages.linux-firmware}/lib/firmware/qcom/a650_sqe.fw \
          ${pkgs.buildPackages.linux-firmware}/lib/firmware/qcom/a650_gmu.bin \
          $out/lib/firmware/qcom/
      '';
    in
    {
      options.alioth.firmware = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        description = "The firmware the phone loads.";
      };

      config = {
        alioth.firmware = [
          vendorFirmware
          radioFirmware
          gpuFirmware
        ];

        hardware.firmware = config.alioth.firmware;

        hardware.enableRedistributableFirmware = false;
      };
    };
}
