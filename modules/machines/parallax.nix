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
    diskoConfig = inputs.self.diskoConfigurations.workstation-legacy;
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

        disko.devices.disk.main.device = "/dev/disk/by-id/nvme-ZHITAI_Ti600_1TB_ZTA601TAB240960FR7";

        hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
      };
    nixosModule = {
      boot.kernelParams = [
        "video=DP-1:3840x2160@60"
        "video=DP-3:2560x1440@60,rotate=90"
      ];
      swapDevices = [
        {
          device = "/swapfile";
          size = 32 * 1024;
          priority = 10;
        }
      ];
      # Hibernating to a swapfile needs a resume device and offset this machine
      # does not have, so only suspend is available.
      systemd.sleep.settings.Sleep.AllowHibernation = false;
    };
    # Workspace 1 stays on the Odyssey; the portrait side display starts at 10.
    homeModule = {
      wayland.windowManager.hyprland.settings = {
        config.cursor.default_monitor = "DP-1";
        monitor = [
          {
            output = "DP-1";
            mode = "3840x2160@120";
            position = "1440x416";
            # 4/3 scaling: a 2880x1620 logical area, larger than 150%'s
            # 2560x1440, at the cost of matching DP-3's 93 ppi.
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
