{ inputs, ... }:
{
  machines.edge = {
    system = "x86_64-linux";
    imports = with inputs.self.modules.aspects; [
      base
      server
      bios
      tailscale
      caddy
      nvirellia-im
      gatus
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

    # The monitors this host runs. It sits outside the services it checks, so a
    # failure in the machine that serves them still reaches the status page. The
    # tailnet entries are the Services neko-sphere advertises; the local ones
    # cover this host itself, and the NetBird tunnel that only neko-sphere can
    # see is not carried over.
    nixosModule =
      { config, ... }:
      let
        tailnet = config.constants.getTailnetFqdn;
      in
      {
        # Automatic HTTPS issues a certificate per name once its A/AAAA record
        # resolves here, so pointing the names at this host is the whole
        # deployment step. The site keeps the upstream module's default port.
        services.caddy.virtualHosts = {
          "status.nvirellia.im".extraConfig = "reverse_proxy 127.0.0.1:3001";
          "nvirellia.im" = {
            serverAliases = [ "www.nvirellia.im" ];
            extraConfig = "reverse_proxy 127.0.0.1:8080";
          };
        };

        services.gatus.settings.endpoints = [
          {
            name = "Freezer";
            group = "Neko Sphere";
            url = "http://${tailnet "nsphere-freezer"}/";
            conditions = [ "[STATUS] == 200" ];
          }
          {
            name = "Magpie gateway";
            group = "Neko Sphere";
            url = "http://${tailnet "nsphere-magpie-api"}/v1/models";
            conditions = [ "[STATUS] == 401" ];
          }
          {
            name = "Magpie UI";
            group = "Neko Sphere";
            url = "http://${tailnet "nsphere-magpie"}/";
            conditions = [ "[STATUS] == 401" ];
          }
          {
            name = "Paseo daemon";
            group = "Neko Sphere";
            url = "http://${tailnet "nsphere-paseo"}/api/health";
            conditions = [ "[STATUS] == 200" ];
          }
          {
            name = "nvirellia.im";
            group = "Noa's IVs";
            url = "https://nvirellia.im/";
            conditions = [ "[STATUS] == 200" ];
          }
          {
            name = "nuts.nvirellia.im";
            group = "Noa's IVs";
            url = "https://nuts.nvirellia.im/";
            conditions = [ "[STATUS] == 200" ];
          }
          {
            name = "SSH";
            group = "Edge";
            url = "tcp://127.0.0.1:22";
            conditions = [ "[CONNECTED] == true" ];
          }
          {
            name = "Gatus";
            group = "Edge";
            url = "http://127.0.0.1:3001/";
            conditions = [ "[STATUS] == 200" ];
          }
        ];
      };
  };
}
