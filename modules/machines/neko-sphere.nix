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
      tailscale
      magpie
      netbird-userspace
      obsidian-headless
      podman
      portainer
      paseo-daemon
      paseo-deploy
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
          # A container on 127.0.0.1:8080.
          nsphere-freezer.endpoints."tcp:80" = "http://127.0.0.1:8080";

          # Magpie's browser page and gateway API are one process on two ports,
          # so each gets its own name; both Services answer on 443.
          nsphere-magpie.endpoints."tcp:80" = "http://127.0.0.1:3430";
          nsphere-magpie-api.endpoints."tcp:80" = "http://127.0.0.1:3425";

          # The personal site's container is published on 127.0.0.1:8081. The
          # HTTPS endpoint terminates the tailnet certificate here; a later
          # Funnel entry points at the same local backend for public traffic.
          nsphere-nvirellia-im.endpoints."tcp:80" = "http://127.0.0.1:8081";

          # Portainer serves its own HTTPS listener with a self-signed
          # certificate, so the layer-7 handler terminates the service's
          # trusted certificate and skips verification of the upstream one.
          nsphere-portainer.endpoints."tcp:80" = "https+insecure://127.0.0.1:9443";

          # The Paseo daemon serves HTTP and WebSocket on one port.
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

      # The deploy broker switches this host to the newest revision of this ref,
      # so it follows the published repository rather than any local checkout.
      services.paseo-deploy.flake = "github:pelikanade/flake";
    };
  };
}
