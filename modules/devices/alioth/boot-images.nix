{
  flake.modules.nixos.alioth =
    {
      config,
      pkgs,
      ...
    }:
    let
      inherit (pkgs) buildPackages;
    in
    {
      # The vendor images this device ships pair a header version 3 boot image,
      # which carries the kernel and the initramfs, with a vendor boot image
      # that carries the device tree and the command line. That is the layout
      # its bootloader boots: the same kernel and device tree in a header
      # version 0 image with the device tree appended is rejected without a
      # word, so this port does not use it.
      system.build.aliothBootImage =
        buildPackages.runCommand "alioth-boot.img"
          {
            nativeBuildInputs = [ buildPackages.android-tools ];
          }
          ''
            mkbootimg \
              --header_version 3 \
              --kernel ${config.alioth.kernel}/Image \
              --ramdisk ${config.system.build.initialRamdisk}/initrd \
              --pagesize 4096 \
              --output $out
          '';

      system.build.aliothVendorBoot =
        buildPackages.runCommand "alioth-vendor_boot.img"
          {
            nativeBuildInputs = [
              buildPackages.android-tools
              buildPackages.cpio
              buildPackages.findutils
            ];
          }
          ''
            # The system initramfs travels in the boot image; the two ramdisks
            # are concatenated, so this one stays empty.
            ${buildPackages.coreutils}/bin/mkdir -p empty
            ${buildPackages.findutils}/bin/find empty -print0 |
              ${buildPackages.cpio}/bin/cpio --null -o -H newc --quiet > vendor_ramdisk.cpio

            mkbootimg \
              --header_version 3 \
              --vendor_boot $out \
              --vendor_ramdisk vendor_ramdisk.cpio \
              --dtb ${config.alioth.deviceTree} \
              --vendor_cmdline "${config.alioth.kernelCmdline}" \
              --base 0x00000000 \
              --kernel_offset 0x00008000 \
              --ramdisk_offset 0x01000000 \
              --tags_offset 0x00000100 \
              --dtb_offset 0x1f00000 \
              --pagesize 4096 \
              --output discard-boot.img
          '';

      # That boot image is unsigned, and the bootloader only starts an
      # unverified boot image on a slot whose verification is switched off.
      # An empty vbmeta with both flags set says exactly that, and only slot B
      # ever receives it: slot A keeps the vendor system's own.
      system.build.aliothVbmeta =
        buildPackages.runCommand "alioth-vbmeta.img"
          {
            nativeBuildInputs = [ buildPackages.android-tools ];
          }
          ''
            avbtool make_vbmeta_image --flags 3 --output $out
          '';

      system.build.aliothRootfsImage =
        buildPackages.callPackage "${pkgs.path}/nixos/lib/make-ext4-fs.nix"
          {
            storePaths = [ config.system.build.toplevel ];
            volumeLabel = config.alioth.rootLabel;
            # The initramfs resolves this path to learn which closure to hand
            # over to. Pointing it at the profile rather than at the image's own
            # closure is what lets a system switched over SSH be the one the
            # next boot runs: the profile starts as that closure and
            # `switch-to-configuration` moves it on.
            populateImageCommands = ''
              mkdir -p ./files/nix/var/nix/profiles
              ln -s ${config.system.build.toplevel} ./files/nix/var/nix/profiles/system
              ln -s /nix/var/nix/profiles/system/init ./files/init
            '';
          };

      system.build.aliothWriteBoot = pkgs.writeShellScriptBin "alioth-write-boot" ''
        set -eu

        check() {
          image=$1
          label=$2
          magic=$3
          part=/dev/disk/by-partlabel/$label

          [ -b "$part" ] || { echo "$part is not a block device" >&2; exit 1; }
          [ "$(${pkgs.coreutils}/bin/head -c 8 "$image")" = "$magic" ] || {
            echo "$image does not start with $magic" >&2
            exit 1
          }
          [ "$(${pkgs.coreutils}/bin/stat -c %s "$image")" -le \
            "$(${pkgs.util-linux}/bin/blockdev --getsize64 "$part")" ] || {
            echo "$image does not fit in $part" >&2
            exit 1
          }
        }

        write() {
          image=$1
          label=$2
          magic=$3
          part=/dev/disk/by-partlabel/$label

          ${pkgs.coreutils}/bin/dd if="$image" of="$part" bs=4M conv=fsync status=none

          [ "$(${pkgs.coreutils}/bin/head -c 8 "$part")" = "$magic" ] || {
            echo "$part does not read back as $magic" >&2
            exit 1
          }
          echo "$label written"
        }

        # Both images are checked before either partition is touched, so a bad
        # image cannot leave the phone with half of a new pair.
        check "$1" boot_b ANDROID!
        check "$2" vendor_boot_b VNDRBOOT

        write "$1" boot_b ANDROID!
        write "$2" vendor_boot_b VNDRBOOT
      '';
    };
}
