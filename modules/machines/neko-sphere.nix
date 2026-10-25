{ inputs, ... }:
{
  machines.neko-sphere = {
    system = "x86_64-linux";
    imports = with inputs.self.modules.aspects; [
      base
      server
      efi
      i18n
      substituter-cn
      sing-box
      tailscale
      magpie
      netbird-userspace
      obsidian-headless
      podman
      paseo-daemon
      freezer
      harmonia
      gh
      avalanche-runner
      avalanche-server
      update-packages-runner
      tailscale-ingress
      probe-agent
      zswap
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

        # Tailscale Services this host advertises. Each name and its endpoints
        # are defined in the tailnet's admin console; this is only the local
        # forwarding table. HTTP and HTTPS targets are Tailscale's L7 handlers,
        # so the tailnet certificate is terminated here; a `tcp` target would
        # forward the connection unmodified instead.
        services.tailscale-ingress.services = {
          nsphere-freezer.endpoints."tcp:80" = "http://127.0.0.1:8080";
          nsphere-cache.endpoints."tcp:80" = "http://127.0.0.1:5000";

          nsphere-magpie.endpoints."tcp:80" = "http://127.0.0.1:3430";
          nsphere-magpie-api.endpoints."tcp:80" = "http://127.0.0.1:3425";

          nsphere-paseo.endpoints."tcp:80" = "http://127.0.0.1:6767";
        };

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
    nixosModule = {
      programs.git.config.user = {
        name = "Felis catus 'Clonazepam' Suzume";
        email = "suzume@neko-sphere.lotus.local";
      };

      services.netbird-userspace.tunnels.techinteaching = {
        localPort = 18083;
        address = "172.0.161.24";
        port = 8083;
      };

      # zswap compresses swapped pages into a RAM pool and writes them here when
      # that pool fills, so the file is both what zswap needs as a backing store
      # and the capacity behind it. Without it the kernel has nothing to page out
      # and every shortfall reaches the OOM killer.
      swapDevices = [
        {
          device = "/swapfile";
          size = 32 * 1024;
        }
      ];

      # Hibernating to a swapfile needs a resume device and offset this machine
      # does not have, so only suspend is available.
      systemd.sleep.settings.Sleep.AllowHibernation = false;
    };
  };
}
