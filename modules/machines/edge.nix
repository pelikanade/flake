{ inputs, ... }:
{
  machines.edge = {
    system = "x86_64-linux";
    imports = with inputs.self.modules.aspects; [
      base
      server
      bios
      tailscale
      zswap
      auto-upgrade-no-build
    ];
    diskoConfig = inputs.self.diskoConfigurations.ext4-server-bios;
    hardware =
      { modulesPath, ... }:
      {
        imports = [
          (modulesPath + "/installer/scan/not-detected.nix")
        ];

        boot = {
          initrd.availableKernelModules = [
            "virtio_pci"
            "virtio_scsi"
            "sd_mod"
            "sr_mod"
          ];
          initrd.kernelModules = [ ];
          kernelModules = [ ];
          extraModulePackages = [ ];
        };

        # The provider gives this host a static address on its single virtio NIC
        # and runs no DHCP server on that link, so the interface is matched by
        # MAC: the predictable name the kernel picks for it is not part of the
        # contract. The same link announces an IPv6 prefix by router
        # advertisement, which is the only address a fresh installation has
        # until the static IPv4 configuration below applies.
        networking = {
          hostName = "edge";
          domain = "nvirellia.im";
          useNetworkd = true;
        };

        systemd.network.networks."10-wan" = {
          matchConfig.MACAddress = "00:16:3e:23:b0:6a";
          networkConfig = {
            Address = "203.88.112.220/24";
            Gateway = "203.88.112.1";
            DNS = [
              "8.8.8.8"
              "8.8.4.4"
            ];
            IPv6AcceptRA = true;
          };
        };

        # A QEMU guest drives its virtio devices from in-kernel drivers; the
        # redistributable firmware blobs, which dominate a default closure at
        # roughly a gigabyte, have nothing here to load. The host applies
        # microcode updates to the CPU this guest runs on.
        hardware.enableRedistributableFirmware = false;

        disko.devices.disk.main.device = "/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi0-0-0-0";
      };
  };
}
