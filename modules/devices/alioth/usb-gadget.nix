# The USB gadget that gives the phone a serial console and a network link over
# the single USB port it has.
{
  flake.modules.nixos.alioth =
    {
      config,
      pkgs,
      ...
    }:
    let
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
    in
    {
      # The gadget script is deliberately *not* listed in
      # `boot.initrd.systemd.storePaths`. Listing it made the initrd run this
      # unit for the first time, and on this port a boot with it never reached
      # switch-root: the hardware watchdog fired a pretimeout and reset the
      # phone. A serial console during the initramfs is not worth an unbootable
      # device, so the unit stays in the initrd without the script and fails
      # with "No such file or directory" as it always did.
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

      # The ethernet function of the gadget is matched by its address, which
      # is the one the script above gives it.
      systemd.network.networks."10-usb-gadget" = {
        matchConfig.MACAddress = gadgetDeviceMac;
        address = [ "${gadgetAddress}/${toString gadgetPrefixLength}" ];
        linkConfig.RequiredForOnline = false;
        networkConfig.ConfigureWithoutCarrier = true;
      };
    };
}
