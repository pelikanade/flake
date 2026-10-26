# Support for the Xiaomi POCO F3 / Redmi K40 / Mi 11X (codename alioth), a
# Qualcomm SM8250 phone that boots a headless NixOS.
#
# The device has no NixOS bootloader. Its Qualcomm ABL bootloader boots the
# layout the vendor images use: a header version 3 boot image with the kernel
# and the initramfs from `boot_b`, and a vendor boot image with the device tree
# and the command line from `vendor_boot_b`. The root filesystem is an ext4
# image on the `userdata` partition. This module builds all of them, as
# `system.build.aliothBootImage`, `aliothVendorBoot`, `aliothVbmeta` and
# `aliothRootfsImage`, and the writer `aliothWriteBoot` that puts the first two
# on the phone from the running system.
{
  flake.modules.nixos.alioth =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      # The phone's kernel is a Linux 6.19.6 fork that the postmarketOS SM8250
      # port maintains, because upstream has no device tree for this phone.
      # The fork, its configuration, and the patch adding the device tree,
      # panel, and touchscreen drivers are the ones the port is tested with;
      # `kernel-config.aarch64` is the complete configuration this build uses,
      # and the symbols this device needs changed are changed in it.
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
        ];
      };

      # The phone's own firmware, taken from the port's extraction of the
      # vendor images. The ADSP, CDSP, SLPI, and Venus firmware blobs live
      # here; the GPU firmware comes from linux-firmware.
      firmware = pkgs.buildPackages.runCommand "alioth-firmware" { } ''
        mkdir -p $out
        cp -a ${
          pkgs.buildPackages.fetchzip {
            url = "https://github.com/N1kroks/firmware-xiaomi-alioth/archive/95dfcdf6b154c00af3e093db82015cda90f4299a.tar.gz";
            hash = "sha256-hk/r6p0/d/YLii1B4WHp9I9Y+QBfZOTmYefWfRNa7Lk=";
          }
        }/* $out/
      '';

      # The WiFi and Bluetooth firmware comes from `linux-firmware`, which the
      # default firmware closure leaves out; only what this handset's radios
      # read is taken. The WiFi driver loads two boot images and a board file,
      # and `btqca` loads a patch and a NVM image. `regulatory.db` is not here
      # because `networking.wireless` installs it with the database itself.
      radioFirmware = pkgs.buildPackages.runCommand "alioth-radio-firmware" { } ''
        mkdir -p $out/lib/firmware/ath11k $out/lib/firmware/qca
        cp -a ${pkgs.buildPackages.linux-firmware}/lib/firmware/ath11k/QCA6390 \
          $out/lib/firmware/ath11k/
        cp -a \
          ${pkgs.buildPackages.linux-firmware}/lib/firmware/qca/htbtfw20.tlv \
          ${pkgs.buildPackages.linux-firmware}/lib/firmware/qca/htnv20.bin \
          $out/lib/firmware/qca/
      '';

      deviceTree = "${kernel}/dtbs/qcom/sm8250-xiaomi-alioth.dtb";

      # The USB gadget gives the phone a console and a network link over the
      # single USB port it has, which is also how it is flashed. Both are
      # configured from the initramfs so that early boot output is visible
      # before anything is loaded from the root filesystem.
      gadgetIdVendor = "0x1d6b";
      gadgetIdProduct = "0x0104";
      gadgetDeviceMac = "02:01:02:03:04:05";
      gadgetHostMac = "02:01:02:03:04:06";

      # The serial number is what names the device on the host side
      # (/dev/serial/by-id), so it carries the phone's own name.
      gadgetSerial = config.networking.hostName;

      # The serial console and the network link are the only ways into a
      # device whose display has no graphical session, and the address is
      # static because nothing on the phone serves DHCP to itself.
      gadgetAddress = "172.16.42.1";
      gadgetPrefixLength = 24;

      # The network the phone joins with its own radio, which is the only path
      # off the device that does not need a host at the far end of its USB
      # cable. Its passphrase is not here: it is a sops secret below.
      wifiSsid = "LoliHouse_5G";

      gadgetScript = pkgs.writeShellScript "alioth-usb-gadget" ''
        set -eu

        gadget=/sys/kernel/config/usb_gadget/alioth
        if [ -d "$gadget" ]; then
          exit 0
        fi

        ${pkgs.coreutils}/bin/mkdir -p /sys/kernel/config
        ${pkgs.util-linux}/bin/mountpoint -q /sys/kernel/config ||
          ${pkgs.util-linux}/bin/mount -t configfs none /sys/kernel/config

        ${pkgs.coreutils}/bin/mkdir -p "$gadget"
        cd "$gadget"

        echo ${gadgetIdVendor} > idVendor
        echo ${gadgetIdProduct} > idProduct
        echo 0x0100 > bcdDevice
        echo 0x0200 > bcdUSB

        ${pkgs.coreutils}/bin/mkdir -p strings/0x409
        echo ${gadgetSerial} > strings/0x409/serialnumber
        echo "NixOS" > strings/0x409/manufacturer
        echo "alioth" > strings/0x409/product

        # acm.usb0 is the serial console the phone prints boot output to and
        # where a getty waits; ecm.usb0 is the ethernet link.
        ${pkgs.coreutils}/bin/mkdir -p functions/acm.usb0 functions/ecm.usb0
        echo ${gadgetDeviceMac} > functions/ecm.usb0/dev_addr
        echo ${gadgetHostMac} > functions/ecm.usb0/host_addr

        ${pkgs.coreutils}/bin/mkdir -p configs/c.1/strings/0x409
        echo "NixOS console and network" > configs/c.1/strings/0x409/configuration
        echo 250 > configs/c.1/MaxPower
        ${pkgs.coreutils}/bin/ln -s functions/acm.usb0 configs/c.1/
        ${pkgs.coreutils}/bin/ln -s functions/ecm.usb0 configs/c.1/

        # The port is a USB-C connector whose role the type-C controller
        # decides. With the cable in a host it reports "device", but the role
        # switch can stay unset until something asks for it, and the
        # controller exposes no UDC to bind a gadget to until it is set.
        for role in /sys/class/usb_role/*/role; do
          if [ -e "$role" ]; then
            echo device > "$role" || true
          fi
        done

        # The controller registers its UDC a moment after the role is set.
        udc=
        for _ in $(${pkgs.coreutils}/bin/seq 50); do
          udc=$(${pkgs.coreutils}/bin/ls /sys/class/udc | ${pkgs.coreutils}/bin/head -n 1)
          [ -n "$udc" ] && break
          ${pkgs.coreutils}/bin/sleep 0.2
        done
        if [ -z "$udc" ]; then
          # The console this message would normally go to does not exist yet,
          # so it reaches the display, which is all there is to look at.
          echo "alioth-usb-gadget: no UDC to bind; the port is not in device role" >&2
          exit 1
        fi

        echo "$udc" > UDC
      '';

      # The gadget exists from the initramfs on, so early boot output is
      # visible before anything is loaded from the root filesystem; the stage 2
      # unit is the same thing for a boot that skipped the initramfs, or for a
      # port whose controller only exposes a UDC later than the initramfs waits.
      gadgetUnit = {
        description = "Expose a serial console and a network link over USB";
        wantedBy = [ "sysinit.target" ];
        before = [
          "sysinit.target"
          "shutdown.target"
        ];
        unitConfig.DefaultDependencies = false;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
      };

      # The window the battery is kept in. This pack's design charge voltage is
      # 4.46 V, and a phone that lives plugged in would otherwise spend its life
      # there. Below the low mark it charges; at the high mark the charge is
      # switched off, which leaves the adapter powering the phone while the
      # battery sits still. `capacity` is clamped at 99% near full and only
      # tracks the pack lower down, so the marks are rough by nature.
      chargeWindowLow = 50;
      chargeWindowHigh = 60;

      # The bootloader appends its own arguments after these, so the phone boots
      # with both. ABL passes `init=/init` as well, which is the same program:
      # the root filesystem carries /init as a symlink to the system closure, and
      # the initramfs hands over to it. Everything else the phone needs on its
      # command line is in `boot.kernelParams`, which also carries the consoles
      # and the log level this configuration asks for.
      kernelCmdline = lib.concatStringsSep " " ([ "init=/init" ] ++ config.boot.kernelParams);

      rootLabel = "alioth";

      # The system closure is cross-compiled, so every tool that runs while
      # building the images has to come from the build platform.
      inherit (pkgs) buildPackages;
    in
    {
      # This machine is aarch64 and the repository has no aarch64 builder, so
      # the workstation cross-compiles the system for it.
      nixpkgs.hostPlatform = "aarch64-linux";
      nixpkgs.buildPlatform = "x86_64-linux";

      boot.kernelPackages = pkgs.linuxPackagesFor kernel;

      # The device's own bootloader boots the Android boot image built below,
      # so NixOS installs no bootloader of its own.
      boot.loader.grub.enable = false;

      # Both consoles the phone has are named here: its display, and the serial
      # port the USB gadget provides once it exists. The log level is raised so
      # that they carry the kernel's informational messages rather than the
      # quieter level this configuration inherits.
      boot.kernelParams = [
        "console=tty0"
        "console=ttyGS0"
      ];
      boot.consoleLogLevel = 7;

      # UFS, the root filesystem, and the USB gadget are all built into the
      # kernel; only the panel driver has to be loaded for the framebuffer
      # console to come up, which happens before the root filesystem is
      # mounted. Listing it as a module to load is also what puts it in the
      # initramfs: stage 1 builds the image from `availableKernelModules` and
      # `kernelModules` together.
      boot.initrd = {
        includeDefaultModules = false;
        kernelModules = [ "panel-samsung-ams667xx01" ];
      };

      # The hand-over from the initramfs to the root filesystem runs the
      # system's activation inside a chroot; when it fails, its output is the
      # only thing that says why, and the initramfs has no getty.
      boot.initrd.systemd.services.initrd-nixos-activation.serviceConfig.StandardOutput =
        "journal+console";
      boot.initrd.systemd.services.initrd-nixos-activation.serviceConfig.StandardError =
        "journal+console";

      # The phone has no TPM, and its kernel carries no TPM drivers, so systemd
      # defaults that pull `tpm-crb` into the initramfs fail its build.
      boot.initrd.systemd.tpm2.enable = false;
      systemd.tpm2.enable = false;

      # The image's filesystem is only as large as the system closure it
      # carries, and `autoResize` is what grows it to the partition before
      # anything mounts or writes to it.
      fileSystems."/" = {
        device = "/dev/disk/by-label/${rootLabel}";
        fsType = "ext4";
        autoResize = true;
      };

      # A headless handset does not carry a documentation closure.
      documentation.enable = false;

      # The root filesystem is a copy of the system closure, placed in a
      # filesystem image whose size follows its contents; the store paths it
      # brings are registered on the first boot of a freshly written image,
      # which is also where a system profile and the `/etc/NIXOS` tag that
      # `nixos-rebuild` wants come from.
      systemd.services.alioth-register-nix-paths = {
        description = "Register the Nix store paths of a freshly written image";
        unitConfig.DefaultDependencies = false;
        unitConfig.ConditionPathExists = "/nix-path-registration";
        wantedBy = [ "sysinit.target" ];
        before = [
          "sysinit.target"
          "shutdown.target"
          "nix-daemon.socket"
          "nix-daemon.service"
        ];
        after = [ "local-fs.target" ];
        conflicts = [ "shutdown.target" ];
        restartIfChanged = false;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          ${lib.getExe' config.nix.package.out "nix-store"} --load-db < /nix-path-registration

          # nixos-rebuild requires a "system" profile and an /etc/NIXOS tag.
          touch /etc/NIXOS
          ${lib.getExe' config.nix.package.out "nix-env"} -p /nix/var/nix/profiles/system --set /run/current-system

          rm -f /nix-path-registration
        '';
      };

      # The bootloader counts unsuccessful boots and switches to the other
      # slot after a few, so every boot has to mark its slot as successful.
      systemd.services.alioth-mark-boot-successful = {
        description = "Mark the current Android A/B slot as successfully booted";
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${lib.getExe pkgs.qbootctl} -m";
        };
      };

      boot.initrd.systemd.services.alioth-usb-gadget = gadgetUnit // {
        enable = true;
        # Until the gadget binds there is no serial console, so these lines land
        # on the display.
        serviceConfig = gadgetUnit.serviceConfig // {
          StandardOutput = "journal+console";
          StandardError = "journal+console";
        };
        script = "${gadgetScript}";
      };

      systemd.services.alioth-usb-gadget = gadgetUnit // {
        serviceConfig = gadgetUnit.serviceConfig // {
          ExecStart = gadgetScript;
        };
      };

      # A phone that lives plugged in should not sit on a charger.
      # `charging_enabled` is the switch that works on this charger: writing 0
      # stops the charge, and writing 0 then 1 starts one. The other writable
      # property, `current_max`, did nothing a two-hour controlled run could see
      # — with it at 0 the cell went on charging — so it is not touched.
      #
      # Holding the window does not take the supply away from the system: the
      # adapter powers the phone whether or not the cell is charging, which the
      # measurements in docs/alioth.md show, and current the cell is not taking
      # is current the system can have.
      systemd.services.alioth-charge-window = {
        description = "Keep the battery inside a charge window";
        wantedBy = [ "multi-user.target" ];
        after = [ "sysinit.target" ];
        serviceConfig = {
          Type = "simple";
          Restart = "always";
          RestartSec = 60;
        };
        script = ''
          set -eu

          charger=/sys/class/power_supply/pm8150b-charger
          battery=/sys/class/power_supply/qcom-battery
          low=${toString chargeWindowLow}
          high=${toString chargeWindowHigh}

          # Both power supplies appear seconds after this starts, and reading
          # them before they do is what made this unit restart in a loop.
          for _ in $(${pkgs.coreutils}/bin/seq 300); do
            if [ -r "$charger/charging_enabled" ] && [ -r "$battery/capacity" ]; then
              break
            fi
            ${pkgs.coreutils}/bin/sleep 1
          done

          while :; do
            capacity=$(${pkgs.coreutils}/bin/cat "$battery/capacity")

            if [ "$capacity" -ge "$high" ]; then
              echo 0 > "$charger/charging_enabled"
            elif [ "$capacity" -le "$low" ]; then
              echo 0 > "$charger/charging_enabled"
              ${pkgs.coreutils}/bin/sleep 1
              echo 1 > "$charger/charging_enabled"
            fi

            ${pkgs.coreutils}/bin/sleep 60
          done
        '';
      };

      # A login prompt on the gadget's serial port is the console of a phone
      # without a display session. NixOS installs upstream's
      # serial-getty@.service as a drop-in, and an instantiated template starts
      # only through a target that wants it.
      systemd.services."serial-getty@ttyGS0" = {
        enable = true;
        wantedBy = [ "getty.target" ];
        serviceConfig.Restart = "always";
      };

      networking = {
        useNetworkd = true;
        # The phone's own network is its WiFi: the USB link needs a host at the
        # other end, and this is a device that is meant to run on its own. The
        # passphrase is a sops secret, so wpa_supplicant reads it through its
        # `ext:` password backend from the file sops renders, and `networking.wireless`
        # installs the regulatory database with the option.
        wireless = {
          enable = true;
          networks.${wifiSsid}.pskRaw = "ext:wifi_psk";
          secretsFile = config.sops.templates."alioth-wifi-secrets".path;
        };

        # This kernel carries no `pkttype` match for the iptables backend, and
        # no `nft_fib_inet` for the nftables backend's reverse-path filter. The
        # firewall runs with that filter off because with it on the generated
        # `fib saddr . mark . iif oif exists` rule in the `inet` table fails
        # with `Could not process rule: No such file or directory`, and a
        # firewall unit that fails to start fails every remote `nixos-rebuild
        # switch` with it. The phone forwards nothing, so the filter protects
        # little here; getting it back means `CONFIG_NFT_FIB_INET=m` in the
        # kernel configuration and a new boot image.
        nftables.enable = true;
        firewall = {
          enable = true;
          checkReversePath = false;
        };
      };

      systemd.network.networks."10-usb-gadget" = {
        matchConfig.MACAddress = gadgetDeviceMac;
        address = [ "${gadgetAddress}/${toString gadgetPrefixLength}" ];
        linkConfig.RequiredForOnline = false;
        networkConfig.ConfigureWithoutCarrier = true;
      };

      # Nothing gives the wireless interface an address: it is left to NixOS's
      # own `99-wireless-client-dhcp` network file, which matches any wireless
      # station and takes an address by DHCP.

      # The board file this radio loads carries no MAC address, so the firmware
      # invents one at every boot and the network hands the phone a different
      # address with it. A `.link` file gives the interface a fixed
      # locally-administered address before anything brings it up, which is what
      # keeps the phone at one address across boots. A matching `.link` file
      # replaces the system default instead of adding to it, so the naming
      # policy has to be repeated here: without it the interface stays `wlan0`
      # and everything that names it stops matching.
      systemd.network.links."10-wireless" = {
        matchConfig = {
          Type = "wlan";
          OriginalName = "wlan0";
        };
        linkConfig = {
          NamePolicy = [ "path" ];
          MACAddress = "02:01:02:03:04:07";
        };
      };

      # Power save is off on this interface because the kernel is built without
      # `CONFIG_CFG80211_DEFAULT_PS`, which is the symbol that makes cfg80211
      # set `WIPHY_FLAG_PS_ON_BY_DEFAULT` and turn power save on for every
      # wireless interface as it is created. Nothing else can be asked to leave
      # it off — no `.network` option, no module parameter, no wpa_supplicant
      # setting — and it is worth a factor of four on this link: measured
      # against the gateway, 4.0 ms average and 16 ms worst with it off against
      # 14.8 ms and 73 ms with it on, and nothing lost either way.
      # `modules/devices/alioth/kernel-config.aarch64` carries the symbol.

      # The WiFi passphrase is the phone's only secret and it stays out of the
      # store: sops decrypts it at activation into a file wpa_supplicant reads
      # through its `ext:` backend. The document names this host and the
      # maintainer; the host decrypts it with the SSH key NixOS generates into
      # its root filesystem, which a full flash replaces.
      sops.secrets."alioth-wifi-psk" = {
        sopsFile = config.constants.resources.getSecretPath "alioth-wifi.yaml";
        key = "wifi_psk";
        owner = "root";
        mode = "0400";
      };

      sops.templates."alioth-wifi-secrets" = {
        content = ''
          wifi_psk=${config.sops.placeholder."alioth-wifi-psk"}
        '';
        # wpa_supplicant runs as its own user under the wireless module's
        # hardening, so the file has to belong to that user: root-owned and
        # mode 0400 is what made the daemon log
        # `EXT PW FILE: ... Permission denied` and never find a key.
        owner = "wpa_supplicant";
        group = "wpa_supplicant";
        mode = "0400";
        restartUnits = [ "wpa_supplicant.service" ];
      };

      services.openssh = {
        enable = true;
        hostKeys = [
          {
            path = "/etc/ssh/ssh_host_ed25519_key";
            type = "ed25519";
          }
        ];
      };

      # The device has one owner; root is reachable with their key over the
      # USB link and with their password on the serial console.
      users.users.root = {
        initialHashedPassword = config.constants.nvirellia.hashedPassword;
        openssh.authorizedKeys.keys = [ config.constants.nvirellia.sshPubKey ];
      };

      # The boot partitions are ordinary block devices on the phone, so a
      # kernel, device tree or command line change can be written onto the slot
      # this device boots from over SSH instead of through a fastboot session.
      # The writer is a build output rather than an installed package: the
      # workstation builds it, copies it over with the images, and runs it
      # there, the same way the images themselves are handled. A boot image that
      # does not start leaves the phone needing a fastboot session; ABL's A/B
      # retry counter falling back to slot A after a few failed boots is the
      # recovery that does not.
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

      # The UFS host controller's runtime suspend is the path that took the
      # storage down: with a heavy write burst running, the controller came back
      # from runtime suspend and its vcc rail (PM8150L L17) failed to enable
      # with `-110`, after which it served no IO at all — 99% IO pressure, load
      # 30, and only a power cycle brought it back. Keeping the controller out of
      # runtime suspend stops that path from running; the rails stay powered,
      # which costs nothing on a phone that lives on an adapter.
      services.udev.extraRules = ''
        ACTION=="add", SUBSYSTEM=="platform", DRIVERS=="ufshcd-qcom", ATTR{power/control}="on"
      '';

      hardware.firmware = [
        firmware
        radioFirmware
      ];

      # The default closure of redistributable firmware is close to a
      # gigabyte, and this device loads only the blobs above plus the GPU
      # firmware that will be added with the display.
      hardware.enableRedistributableFirmware = false;

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
              --kernel ${kernel}/Image \
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
              --dtb ${deviceTree} \
              --vendor_cmdline "${kernelCmdline}" \
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

      # An ext4 image holding the system closure and a /init symlink into it,
      # which is what the initramfs executes after mounting this filesystem.
      system.build.aliothRootfsImage =
        buildPackages.callPackage "${pkgs.path}/nixos/lib/make-ext4-fs.nix"
          {
            storePaths = [ config.system.build.toplevel ];
            volumeLabel = rootLabel;
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
    };
}
