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
      gatus
      gh
      tailscale-ingress
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

          nsphere-magpie.endpoints."tcp:80" = "http://127.0.0.1:3430";
          nsphere-magpie-api.endpoints."tcp:80" = "http://127.0.0.1:3425";

          nsphere-nvirellia-im.endpoints."tcp:80" = "http://127.0.0.1:8081";

          nsphere-paseo.endpoints."tcp:80" = "http://127.0.0.1:6767";

          nsphere-gatus.endpoints."tcp:80" = "http://127.0.0.1:3001";
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
    # Agents hosted here commit as the paseo service account and as root, and
    # neither runs Home Manager, so this machine's author identity belongs in the
    # system-wide gitconfig that both read.
    nixosModule = {
      programs.git.config.user = {
        name = "Felis catus 'Clonazepam' Suzume";
        email = "suzume@neko-sphere.lotus.local";
      };

      # Another network's HTTP endpoint, served here on loopback. Neither the
      # endpoint's address nor the network it belongs to is public: the client's
      # management URL and setup key come from its own encrypted document.
      services.netbird-userspace.tunnels.techinteaching = {
        localPort = 18083;
        address = "172.0.161.24";
        port = 8083;
      };

      # Every listener here is bound to loopback, so each check exercises the
      # same path a local client uses. Gatus' default interval is 60 seconds.
      services.gatus.settings.endpoints = [
        {
          name = "Freezer";
          group = "neko-sphere";
          url = "http://127.0.0.1:8080/";
          conditions = [ "[STATUS] == 200" ];
        }
        {
          name = "Magpie gateway";
          group = "neko-sphere";
          url = "http://127.0.0.1:3425/v1/models";
          conditions = [ "[STATUS] == 200" ];
        }
        {
          name = "Magpie UI";
          group = "neko-sphere";
          url = "http://127.0.0.1:3430/";
          conditions = [ "[STATUS] == 401" ];
        }
        {
          name = "nvirellia.im";
          group = "neko-sphere";
          url = "http://127.0.0.1:8081/";
          conditions = [ "[STATUS] == 200" ];
        }
        {
          name = "Paseo daemon";
          group = "neko-sphere";
          url = "http://127.0.0.1:6767/api/health";
          conditions = [ "[STATUS] == 200" ];
        }
        {
          name = "sing-box";
          group = "neko-sphere";
          url = "http://127.0.0.1:9990/version";
          conditions = [ "[STATUS] == 200" ];
        }
        {
          name = "NetBird tunnel";
          group = "neko-sphere";
          url = "tcp://127.0.0.1:18083";
          conditions = [ "[CONNECTED] == true" ];
        }
        {
          name = "SSH";
          group = "neko-sphere";
          url = "tcp://127.0.0.1:22";
          conditions = [ "[CONNECTED] == true" ];
        }
        {
          name = "Gatus";
          group = "neko-sphere";
          url = "http://127.0.0.1:3001/";
          conditions = [ "[STATUS] == 200" ];
        }
      ];

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
