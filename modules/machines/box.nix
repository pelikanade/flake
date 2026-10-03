{ inputs, ... }: {
  machines.box = {
    system = "x86_64-linux";
    imports = with inputs.self.modules.aspects; [
      base
      server
      efi
      i18n
      substituter-cn
      sing-box
      magpie
      paseo-daemon
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

        networking = {
          hostName = "box";
          domain = "lotus.local";
        };
        boot.initrd.availableKernelModules = [ "nvme" ];
        boot.initrd.kernelModules = [ "dm-snapshot" ];
        boot.kernelModules = [ "kvm-amd" ];
        boot.extraModulePackages = [ ];
        disko.devices.disk.main.device = "/dev/nvme0n1";

        nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
        hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
      };
  };
}
