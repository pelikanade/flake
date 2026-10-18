{ inputs, ... }:
{
  machines.parallax = {
    system = "x86_64-linux";
    imports = with inputs.self.modules.aspects; [
      base
      workstation
      efi
      nvidia
      hmcl
      steam
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
            "nvme"
            "xhci_pci"
            "ahci"
            "usbhid"
            "usb_storage"
          ];
          initrd.kernelModules = [ ];
          kernelModules = [ "kvm-amd" ];
          extraModulePackages = [ ];
        };

        networking = {
          hostName = "parallax";
          domain = "lotus.local";
        };

        disko.devices.disk.main.device = "/dev/disk/by-id/nvme-KINGSTON_SKC3000D4096G_50026B768682EAC1";

        hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
      };
    nixosModule = {
      boot.kernelParams = [
        # The portrait side display needs its console mode rotated. DP-1 takes
        # the mode the driver prefers instead: a console mode a monitor does not
        # report to the kernel verbatim is offered to nvidia-drm as a user-defined
        # mode, which it refuses while the display is being restored at resume.
        "video=DP-3:2560x1440@60,rotate=90"
      ];
    };
    homeModule = {
      wayland.windowManager.hyprland.settings = {
        config.cursor.default_monitor = "DP-1";
        monitor = [
          {
            output = "DP-1";
            mode = "3840x2160@120";
            position = "1440x416";
            scale = 1.333333;
            vrr = 3;
          }
          {
            output = "DP-3";
            mode = "2560x1440@165";
            position = "0x0";
            scale = 1;
            transform = 3;
            vrr = 3;
          }
        ];
        workspace_rule = [
          {
            workspace = "1";
            monitor = "DP-1";
            default = true;
          }
          {
            workspace = "10";
            monitor = "DP-3";
            default = true;
          }
        ];
      };
    };
  };
}
