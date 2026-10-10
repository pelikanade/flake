{ inputs, ... }:
{
  machines.asymmetry = {
    system = "x86_64-linux";
    imports = with inputs.self.modules.aspects; [
      base
      workstation
      efi
      secure-boot
      i18n
      substituter-cn
    ];
    diskoConfig = inputs.self.diskoConfigurations.xfs-workstation;
    hardware =
      {
        config,
        lib,
        modulesPath,
        ...
      }:
      {
        imports = [
          (modulesPath + "/installer/scan/not-detected.nix")
        ];

        boot = {
          initrd.availableKernelModules = [
            "xhci_pci"
            "thunderbolt"
            "nvme"
            "usbhid"
            "usb_storage"
            "sd_mod"
          ];
          initrd.kernelModules = [ ];
          kernelModules = [ "kvm-intel" ];
          extraModulePackages = [ ];
        };

        networking = {
          hostName = "asymmetry";
          domain = "lotus.local";
        };

        disko.devices.disk.main.device = "/dev/disk/by-id/nvme-YMTC_YMSS2CD08D25MC_YMB51T0JA25495102F";

        hardware.cpu.intel = {
          npu.enable = true;
          updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
        };
      };
    homeModule = {
      wayland.windowManager.hyprland.settings.monitor = [
        {
          output = "desc:China Star Optoelectronics Technology Co. Ltd MNE007ZA3-4";
          mode = "2880x1800@120";
          position = "auto";
          # 5/3 scaling gives a whole-pixel 1728x1080 logical desktop.
          scale = 1.666667;
          vrr = 3;
        }
      ];
    };
  };
}
