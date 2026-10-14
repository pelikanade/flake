{ inputs, ... }: {
  machines.neko-sphere = {
    system = "x86_64-linux";
    imports = with inputs.self.modules.aspects; [
      base
      server
      efi
      i18n
      substituter-cn
      sing-box
      magpie
      obsidian-headless
      podman
      portainer
      paseo-daemon
      gh
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
          hostName = "neko-sphere";
          domain = "lotus.local";
        };
        boot.initrd.availableKernelModules = [ "nvme" ];
        boot.initrd.kernelModules = [ "dm-snapshot" ];
        boot.kernelModules = [ "kvm-amd" ];
        boot.extraModulePackages = [ ];
        disko.devices.disk.main.device = "/dev/nvme0n1";

        hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
      };
    # Agents hosted here commit as the paseo service account and as root, and
    # neither runs Home Manager, so this machine's author identity belongs in the
    # system-wide gitconfig that both read.
    nixosModule = {
      programs.git.config.user = {
        name = "Felis catus 'Clonazepam' Suzume";
        email = "suzume@neko-sphere.lotus.local";
      };
    };
  };
}
